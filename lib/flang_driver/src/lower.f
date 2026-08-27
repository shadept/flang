// AST -> FIR lowering: a type-checked `Module` (plus its `TypeCheckResult`, for per-node types by
// span) becomes a `flang_codegen` `IrModule`.
//
// Milestone 1 scope: straight-line single-block scalar functions - params, immutable `let`,
// int/bool literals, arithmetic/bitwise ops, `return`. Milestone 2 adds direct and UFCS calls to
// functions whose signatures lower. Milestone 3 adds branching: comparisons, short-circuit
// `and`/`or`, `if` (as expression and statement), `while` / `loop` / `for` over an integer range,
// and `break` / `continue`. Milestone 4 adds assignment, address-of and dereference, which is what
// makes every local a slotted place (see `LocalSlot`). Out-of-subset exprs lower to a placeholder;
// unsupported signatures skip.
//
// Milestone 5 adds `match` and indexing - the latter as calls to the operator the checker picked
// (`op_index_ref` is a place, `op_index` is not) and as `base + i * stride` for built-in arrays and
// slices.
//
// Milestone 6 adds aggregate parameters and returns. An aggregate crosses a call boundary by
// pointer: the caller passes the value's address and the callee copies into its own slot (so
// mutating a by-value parameter never writes through - value semantics); an aggregate return
// travels through a caller-allocated buffer passed as a trailing `sret` pointer. The pointer-niche
// `Option(&T)` is classified as a scalar (`ptr`), not an aggregate - its value IS the payload
// pointer. Because the checker's coercions rewrite a node's recorded type in place, every site that
// knows a value's true source type checks it against the node type before handing bytes over - see
// `repr_compatible`.
//
// Milestone 7 adds enum variant construction (`Some(x)`, `Color.Red`, bare `None`) - the tagged
// form builds tag-then-payload into a fresh slot, the pointer-niche `Option(&T)` is a retype
// (`None` is the null pointer, `Some(p)`'s value IS its payload pointer). Multi-payload
// construction refuses, matching the pattern side.
//
// Milestone 8 adds the optional operators: `a ?? b` as a built-in Option branch (short-circuit
// right side, niche and tagged, unwrap and chain forms) and `a?` as the checker-recorded `op_try`
// call plus a tag branch and an early return - the reference's desugar, emitted directly.
//
// Milestone 9 adds the data segment: a string literal's decoded bytes are interned program-wide
// into a null-terminated global, and each use builds a `String { ptr, len }` view into a stack
// slot. Float literals parse to `FloatConst` and work in patterns (ordered fcmp); a literal whose
// node type never resolved refuses rather than emit a double into integer arithmetic. M9 also adds
// `defer` (per-function schedule with per-scope marks, mirroring the reference: normal exits pop
// and emit their scope's suffix, escaping jumps emit down to their target depth without popping)
// and string interpolation, which lowers by replaying the checker-recorded StringBuilder desugar as
// an ordinary block.
//
// Still out of subset: range slicing over a built-in base (`xs[a..b]`), which has to build a
// `Slice` with bounds clamped against the base's length; `op_set_index`, so a value-form index
// stays unassignable; calls that omit defaulted arguments; and binary/unary operators over
// aggregates, whose user-defined operator functions the checker does not record on the node.
//
// The complete per-feature coverage matrix is docs/self-host.md - keep it in sync with any change
// to what lowers or refuses here.
//
// `ast` and `fir` both export `BinaryOp`/`UnaryOp`; neither is named here (operators match AST
// variants and emit through builder methods).

import std.set
import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import std.test
import flang_core.span
import flang_parser.ast
import flang_parser.comptime
import flang_parser.lexer
import flang_typer.type
import flang_typer.interner
import flang_typer.node_id
import flang_typer.result
import flang_typer.nominal_registry
import flang_typer.function_registry
import flang_typer.inference_results
import flang_typer.scheme
import flang_typer.specialization
import flang_typer.well_known
import flang_codegen.fir
import flang_codegen.builder
import flang_analysis.analyze
import flang_driver.layout
import flang_driver.symbol_table

// Lowering context - everything the walk needs besides the block cursor and the local environment.
// Bundled rather than threaded separately so later milestones (loop labels for M3, arm state for
// M5) get a home without touching every signature again.
type LowerCtx = struct {
    result: &TypeCheckResult
    // A DIRECT reference to the result's type table. Interning during lowering (RTTI shapes, slice
    // views) mutates the table, and a mutation reached as `ctx.result.interner` crosses a reference
    // field two hops deep, which does not stick
    // (docs/known-issues.md). One hop through this field does.
    it: &TypeInterner
    // The active specialization's private result tables, consulted before `result` (M10). Node ids
    // are span fingerprints shared by every instantiation of a template body; the overlay is what
    // keys this walk's types/targets/operators to THIS instantiation. Null while lowering ordinary
    // declarations.
    overlay: &InferenceResults?
    syms: &SymbolTable
    allocator: &Allocator?
    loops: List(LoopFrame)
    // Destination of the current function's aggregate return value (the caller-provided sret
    // buffer) and the byte count to copy into it. Null while lowering a function with a scalar or
    // void return.
    sret: Operand?
    ret_size: u64
    // Data segment (M9). `strings` interns literals program-wide by their raw source text - two
    // spellings of the same bytes ("A" vs "A") mint two globals, which is harmless duplication for
    // zero decode work on repeat literals. `str_globals` collects the minted globals;
    // `flush_strings` moves them into the IrModule after the walk.
    strings: Dict(String, StrData)
    str_globals: List(Global)
    // Defer schedule, mirroring the reference's per-function stack + per-scope marks: `defers`
    // holds every pending deferred expression (copies of the AST nodes - their children stay in the
    // module's arena), `defer_marks` the stack depth at each open block scope. Normal scope exit
    // emits and pops its own suffix; `return`, `break`, `continue` and `?` emit down to their
    // target depth WITHOUT popping - they traverse scopes the owning blocks still close themselves.
    defers: List(Expr)
    defer_marks: List(usize)
    // True while a defer flush is being emitted. An escaping construct inside a deferred expression
    // (`defer { return }`, `?` in a defer - E2091 in the reference) would recurse into the flush
    // forever; the guard refuses the function instead.
    flushing: bool
    // TEMPORARY SCAFFOLD - see `unlowerable`. Delete with it.
    blocked: bool
    // First deep refusal reason for the current function, when a refusal site recorded one -
    // surfaces in the skip note. Same scaffold.
    blocked_note: String?
    // The name the refusal is *about* (the unbound identifier, the callee that was not callable). A
    // view into source, like `blocked_note`, so the skip report can say which symbol without
    // allocating.
    blocked_subject: String?
    // RFC-014: lambda bodies enqueued at their literal sites, emitted as module-level functions
    // after the main walk (a body can enqueue nested lambdas, so the drain is index-based).
    pending_lambdas: List(PendingLambda)
    // Compile-time context #if conditions evaluate against. Host by default; a cross-target build
    // overrides it at construction.
    comptime: ComptimeCtx
    // M11 globals: module-level consts that lowered, keyed by the FQN the checker records in
    // `RtConst`. Membership is the readable gate - a const whose initializer refused has no entry,
    // so its readers refuse (absent, never silently zero).
    consts: Dict(String, ConstInfo)
    // Init-function symbols in emission order; `wire_const_inits` calls each at the top of `main`.
    // ponytail: init order is declaration order, not dependency order - a const whose INITIALIZER
    // reads another const's VALUE (not address) may read zeros. No such const exists in-tree;
    // topo-sort when one does.
    const_inits: List(String)
    // Owned backing for const global/init symbol names; the IrModule and `consts` reference them as
    // views. Leaks with the ctx, like `syms`.
    owned_syms: List(OwnedString)
}

// One lowered module-level constant: its global's symbol, its init function's symbol, and its
// declared (initializer) type. The symbol views point into `LowerCtx.owned_syms`.
type ConstInfo = struct {
    sym: String
    init_sym: String
    ty: Ty
}

// A lambda body awaiting emission. `lam`/`info` are shallow copies (children stay in the module
// arena / the checker's tables); `overlay` is the specialization overlay active at the literal
// site, so a lambda inside an instantiated template body lowers against that instantiation's node
// types.
type PendingLambda = struct {
    lam: LambdaExpr
    info: LambdaInfo
    overlay: &InferenceResults?
}

// Closure emission info for `lower_function_body`: the synthesized env struct's type and the
// capture list whose fields it binds.
type LoweredClosure = struct {
    ty: Ty
    captures: &List(CaptureRec)
}

// An interned string literal: the data-segment global holding its null-terminated bytes, and the
// decoded length (terminator excluded) - exactly the two fields a `String { ptr, len }` view needs.
type StrData = struct {
    name: String
    len: usize
}

// ─────────────────────────────────────────────────────────────────────────
// TEMPORARY SCAFFOLD - remove when lowering covers the language
// ─────────────────────────────────────────────────────────────────────────
//
// `blocked` / `unlowerable` / `IrModule.skipped` exist only because lowering currently handles a
// subset of FLang. They are a crutch for the milestone period, not a design feature, and they are
// meant to be deleted.
//
// What they do: mark the function being lowered as containing a construct this milestone cannot
// represent, so `lower_function` refuses to emit it. The alternative - emitting it with placeholder
// zeros - produces a program that links, runs, and silently computes the wrong answer. A missing
// function fails loudly at link time; a wrong one never fails at all.
//
// REMOVAL CONDITION: when `lower_expr` and `lower_stmt` no longer need a catch-all placeholder arm
// - i.e. every `Expr` and `Stmt` variant lowers - there is nothing left to block. At that point
// delete: this function, `LowerCtx.blocked`, the skip branch in `lower_function`,
// `IrModule.skipped` and its `was_skipped` test helper, and every `unlowerable(ctx)` call site. The
// compiler should then either lower a construct or report a diagnostic, never quietly drop a
// function.
//
// ponytail: milestone-period crutch; delete once lowering is total. Tracked in
// docs/known-issues.md.
fn unlowerable(ctx: &LowerCtx) Operand {
    ctx.blocked = true
    return Operand.IntConst(0)
}

// `unlowerable` with a reason - the first one a function hits lands in its skip note. Same
// temporary scaffold.
fn unlowerable_why(ctx: &LowerCtx, why: String) Operand {
    if !ctx.blocked {
        ctx.blocked_note = Some(why)
    }
    return unlowerable(ctx)
}

// `unlowerable_why` plus the name the refusal is about, so the skip report points at a symbol
// instead of a category.
fn unlowerable_about(ctx: &LowerCtx, why: String, subject: String) Operand {
    if !ctx.blocked {
        ctx.blocked_subject = Some(subject)
    }
    return unlowerable_why(ctx, why)
}

// Enclosing loops, innermost last, so `break` and `continue` can name the block they branch to.
// Both fields are FIR block labels - non-owning `String` views of labels the `FunctionBuilder`
// owns, which is the form `br`/`br_if` take.
type LoopFrame = struct {
    // Where `continue` goes: the block that performs one iteration's bookkeeping and closes the
    // back edge. For `while` and `loop` that is the loop head itself; for `for` it is the block
    // that advances the induction variable before re-entering the head.
    latch: String
    // Where `break` goes: the first block after the loop.
    exit: String
    // `ctx.defers.len` when the loop was entered: `break` / `continue` fire every defer registered
    // past this point - the scopes the jump escapes through - before branching.
    defer_depth: usize
}

// Lexical environment: a stack of bindings, innermost last. A block marks the stack on entry and
// pops back to the mark on exit, so a `let` inside a branch or loop body cannot outlive it and an
// inner binding shadows an outer one of the same name. Linear scan - function scopes are small, and
// a `Dict` cannot pop a scope.
// A local's storage. Every local is a place: it has an address, so `x = v`, `&x`, and mutation
// across a loop back edge all work the same way and need no "which locals escape SSA" analysis - an
// analysis whose gaps would be silent wrong code rather than a diagnostic.
//
// Slots are not about registers: FIR is an infinite-register SSA IR, and choosing real registers is
// the backend's job. A slot exists because an SSA value has no address and cannot be reassigned,
// and some locals need both.
//
// ponytail: slotting *every* local overshoots - one that is never assigned nor address-taken could
// stay a plain SSA value. The cost is that FIR passes cannot see through the slot's load/store
// traffic to the value inside. The upgrade path is a mem2reg pass over FIR, which is also what
// makes the merge-point cases (loop-carried locals) fall out as block parameters.
type LocalSlot = struct {
    // The local's address. Scalars load and store through it; an aggregate
    // *is* its address, so reading one hands the address straight back.
    addr: Operand
    // FIR type of the stored scalar. Unused for aggregates, which move by byte copy rather than by
    // typed load.
    ty: IrType
    aggregate: bool
    // The binding's checked type, for the representation guard in `read_binding`: a use site whose
    // node type disagrees with this in representation (a coercion the checker applied and recorded
    // over the node) must refuse rather than hand the binding's bytes off as something they are
    // not. Aliases checker-owned storage.
    src: Ty
}

type Env = struct {
    names: List(String)
    bindings: List(LocalSlot)
}

fn new_env(allocator: &Allocator?) Env {
    let n: List(String) = list(8, allocator)
    let b: List(LocalSlot) = list(8, allocator)
    return Env { names = n, bindings = b }
}

// Bind `name` to a stack slot holding a scalar of `ty`, declared as `src`.
fn bind_slot(self: &Env, name: String, addr: Operand, ty: IrType, src: Ty) {
    self.names.push(name)
    self.bindings.push(LocalSlot { addr = addr, ty = ty, aggregate = false, src = src })
}

// Bind `name` to an aggregate of type `src` at `addr`.
fn bind_aggregate(self: &Env, name: String, addr: Operand, src: Ty) {
    self.names.push(name)
    self.bindings.push(LocalSlot { addr = addr, ty = IrType.Ptr, aggregate = true, src = src })
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
        if self.names[i] == name {
            return Some(self.bindings[i])
        }
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
        I8 => 1u64
        I16 => 2u64
        I32 => 4u64
        I64 => 8u64
        F32 => 4u64
        F64 => 8u64
        Ptr => 8u64
        Agg(a) => a.size as u64
    }
}

// Lower every supported top-level function in `ast_module` into a fresh `IrModule`. Non-function
// decls and unsupported functions are skipped.
pub fn lower_module(ast_module: &Module, result: &TypeCheckResult,
    allocator: &Allocator? = null) IrModule {
    let m = module(allocator)
    let sb = symbol_builder(result, allocator)
    sb.add_module(ast_module, "")
    let syms = sb.finish()
    let loop_stack: List(LoopFrame) = list(0, allocator)
    let interner: Dict(String, StrData) = dict(allocator)
    let str_globals: List(Global) = list(0, allocator)
    let defer_stack: List(Expr) = list(0, allocator)
    let defer_marks: List(usize) = list(0, allocator)
    let ctx = LowerCtx {
        result = result,
        it = &result.interner,
        overlay = null,
        syms = &syms,
        allocator = allocator,
        loops = loop_stack,
        sret = null,
        ret_size = 0u64,
        strings = interner,
        str_globals = str_globals,
        defers = defer_stack,
        defer_marks = defer_marks,
        flushing = false,
        blocked = false,
        blocked_note = null,
        blocked_subject = null,
        pending_lambdas = list(0, allocator),
        comptime = host_ctx(),
        consts = dict(allocator),
        const_inits = list(0, allocator),
        owned_syms = list(0, allocator),
    }
    lower_consts(&m, &ctx, ast_module)
    lower_into(&m, &ctx, ast_module, "")
    lower_specializations(&m, &ctx)
    lower_pending_lambdas(&m, &ctx)
    flush_strings(&m, &ctx)
    wire_const_inits(&m, &ctx)
    // ponytail: the symbol table leaks - the IrModule's function names are views into its owned
    // strings, so freeing it here would dangle every name the backend is about to print. Upgrade
    // path: arena-own IrModule names.
    return m
}

// Lower every supported module of a checked project into one `IrModule`, sharing the project-wide
// `TypeCheckResult`. Cross-module references resolve through that result; every function lands in
// one program so the backend links it in a single pass. `fqns` is parallel to `modules`; each
// function's symbol is namespaced by its module so merged same-named functions cannot collide.
pub fn lower_program(modules: &List(Module), fqns: &List(OwnedString), result: &TypeCheckResult,
    comptime_ctx: ComptimeCtx, demanded: &List(bool)? = null,
    allocator: &Allocator? = null) IrModule {
    let m = module(allocator)
    let sb = symbol_builder(result, allocator)
    for i in 0..modules.len {
        sb.add_module(&modules[i], fqns[i].as_view())
    }
    let syms = sb.finish()
    let loop_stack: List(LoopFrame) = list(0, allocator)
    let interner: Dict(String, StrData) = dict(allocator)
    let str_globals: List(Global) = list(0, allocator)
    let defer_stack: List(Expr) = list(0, allocator)
    let defer_marks: List(usize) = list(0, allocator)
    // The BUILD's compile-time context, not the host's: a cross-target build (`--target-os`) must
    // lower the same `#if` branch the checker checked, or the emitted C is the host's branch of a
    // program that type-checked as the target's.
    let ctx = LowerCtx { result = result, it = &result.interner, overlay = null, syms = &syms,
        allocator = allocator, loops = loop_stack, sret = null, ret_size = 0u64, strings = interner,
        str_globals = str_globals, defers = defer_stack, defer_marks = defer_marks,
        flushing = false, blocked = false, blocked_note = null, blocked_subject = null,
        pending_lambdas = list(0, allocator), comptime = comptime_ctx, consts = dict(allocator),
        const_inits = list(0, allocator), owned_syms = list(0, allocator) }
    // A module outside the demand set (RFC-022 §6) was never body-checked: it has no node types to
    // lower, and nothing demanded can reach its functions or constants - identifier, operator and
    // constant resolution are import-scoped. Its foreign declarations still lower: a `#foreign`
    // symbol resolves program-wide without an import. Consts first: bodies in ANY module may read a
    // const from any other, and the readable gate is `ctx.consts` membership.
    for i in 0..modules.len {
        if module_demanded(demanded, i) {
            lower_consts(&m, &ctx, &modules[i])
        }
    }
    for i in 0..modules.len {
        if module_demanded(demanded, i) {
            lower_into(&m, &ctx, &modules[i], fqns[i].as_view())
        } else {
            lower_foreign_decls(&m, &ctx, &modules[i], fqns[i].as_view())
        }
    }
    // A specialization of an undemanded module's template exists only on behalf of undemanded code
    // (an eager constant initializer, a default value) - emitting it would reference that module's
    // unlowered functions.
    let skip_specs: Set(String) = set(allocator)
    defer skip_specs.deinit()
    if demanded.is_some() {
        for i in 0..modules.len {
            if !module_demanded(demanded, i) {
                skip_specs.add(fqns[i].as_view())
            }
        }
    }
    lower_specializations(&m, &ctx, Some(&skip_specs))
    lower_pending_lambdas(&m, &ctx)
    flush_strings(&m, &ctx)
    // ponytail: the symbol table leaks - the IrModule's names borrow its strings (see
    // lower_module).
    //
    // Drop FIRST, wire init calls after: an init function that survives the fixpoint is callable,
    // and a const whose init died takes its READERS down inside the fixpoint (see
    // `reads_dead_global`) - so `main` only ever calls inits that exist, instead of dying because
    // some unrelated module's const could not initialize.
    drop_callers_of_refused(&m, &ctx, allocator)
    wire_const_inits(&m, &ctx)
    return m
}

// TEMPORARY SCAFFOLD (see `unlowerable`): delete with the skip mechanism.
//
// A symbol gets its name when the *signature* lowers, but the body is refused separately and later
// - so a call can name a function that was never emitted. That is a link error, which is loud, but
// it takes the whole program down rather than the one function that cannot be built.
//
// Refusal has to be transitive to be worth anything: dropping a function leaves its own callers
// naming a symbol that just disappeared. So this runs to a fixpoint. It is the counterpart, across
// the call graph, of `blocked` within a body - and it is what makes the milestone property
// ("everything emitted is correct; the rest is absent") hold for calls to generic functions, whose
// bodies stay unlowerable until monomorphization.
fn drop_callers_of_refused(m: &IrModule, ctx: &LowerCtx, alloc: &Allocator?) {
    let defined: Dict(String, bool) = dict(alloc)
    for i in 0..m.functions.len { defined.set(m.functions[i].name, true) }
    for i in 0..m.foreigns.len { defined.set(m.foreigns[i].name, true) }

    // Const global -> its init function: a function READING a const whose init died would see
    // zeros, so it must go too (M11 globals).
    let init_of: Dict(String, String) = dict(alloc)
    for entry in ctx.consts {
        let ci: ConstInfo = entry.value
        init_of.set(ci.sym, ci.init_sym)
    }

    // Fixpoint over names only - dropping a function strands its own callers, and they have to go
    // too.
    let changed = true
    while changed {
        changed = false
        for &f in m.functions {
            if defined.get(f.name).is_none() {
                continue
            }
            let missing = first_undefined_callee(f, &defined)
            if missing.is_some() {
                let _d = defined.remove(f.name)
                m.skipped.push(f.name)
                m.skip_notes.push($"{f.name}: calls undefined `{missing.unwrap()}`")
                changed = true
                continue
            }
            let dead = first_dead_global(f, &init_of, &defined)
            if dead.is_some() {
                let _d = defined.remove(f.name)
                m.skipped.push(f.name)
                m.skip_notes.push($"{f.name}: reads `{dead.unwrap()}` whose initializer was dropped")
                changed = true
            }
        }
    }

    // Compact once the set has settled. A kept function MOVES into `keep` (its buffers now owned by
    // the copy); a dropped one frees its tree here. The stale headers are popped out of both lists,
    // so each function tree is deinited exactly once.
    let keep: List(Function) = list(m.functions.len, alloc)
    for &f in m.functions {
        if defined.get(f.name).is_some() {
            keep.push(f.*)
        } else {
            f.deinit()
        }
    }
    while m.functions.pop().is_some() {}
    m.functions.push_all(keep.as_slice())
    while keep.pop().is_some() {}
    keep.deinit()
    defined.deinit()
}

// The first direct callee of `f` that has no definition in the module. Indirect calls carry no
// symbol and are not checked here. The first const global `f` touches whose init function is no
// longer defined - the read would see zeros. TEMPORARY SCAFFOLD, removed with the skip mechanism.
fn first_dead_global(f: &Function, init_of: &Dict(String, String), defined: &Dict(String,
        bool)) String? {
    for &blk in f.blocks {
        for i in 0..blk.instrs.len {
            let g = instr_dead_global(&blk.instrs[i], init_of, defined)
            if g.is_some() {
                return g
            }
        }
        let g2 = term_dead_global(&blk.terminator, init_of, defined)
        if g2.is_some() {
            return g2
        }
    }
    return null
}

fn instr_dead_global(ins: &Instr, init_of: &Dict(String, String), defined: &Dict(String,
        bool)) String? {
    return ins.* match {
        Binary(x) => two_dead(&x.lhs, &x.rhs, init_of, defined)
        Unary(x) => one_dead(&x.operand, init_of, defined)
        Compare(x) => two_dead(&x.lhs, &x.rhs, init_of, defined)
        Convert(x) => one_dead(&x.operand, init_of, defined)
        StackSlot(_) => null
        Load(x) => one_dead(&x.ptr, init_of, defined)
        Store(x) => two_dead(&x.value, &x.ptr, init_of, defined)
        Gep(x) => two_dead(&x.ptr, &x.offset, init_of, defined)
        Memcpy(x) => {
            let d = two_dead(&x.dst, &x.src, init_of, defined)
            if d.is_some() {
                return d
            }
            one_dead(&x.size, init_of, defined)
        }
        Memset(x) => two_dead(&x.dst, &x.size, init_of, defined)
        Call(x) => list_dead(&x.args, init_of, defined)
        CallIndirect(x) => {
            let d = one_dead(&x.fn_ptr, init_of, defined)
            if d.is_some() {
                return d
            }
            list_dead(&x.args, init_of, defined)
        }
    }
}

fn term_dead_global(t: &Terminator, init_of: &Dict(String, String), defined: &Dict(String,
        bool)) String? {
    return t.* match {
        Br(bt) => list_dead(&bt.args, init_of, defined)
        BrIf(bi) => {
            let d = one_dead(&bi.cond, init_of, defined)
            if d.is_some() {
                return d
            }
            let d2 = list_dead(&bi.then_target.args, init_of, defined)
            if d2.is_some() {
                return d2
            }
            list_dead(&bi.else_target.args, init_of, defined)
        }
        Ret(v) => v match {
            Some(op) => one_dead(&op, init_of, defined)
            None => null
        }
        Unreachable => null
    }
}

fn one_dead(op: &Operand, init_of: &Dict(String, String), defined: &Dict(String, bool)) String? {
    op.* match {
        GlobalRef(g) => {
            let ini = init_of.get(g)
            ini match {
                Some(isym) => {
                    if defined.get(isym).is_none() {
                        return Some(g)
                    }
                }
                None => {}
            }
        }
        _ => {}
    }
    return null
}

fn two_dead(a: &Operand, b: &Operand, init_of: &Dict(String, String), defined: &Dict(String,
        bool)) String? {
    let d = one_dead(a, init_of, defined)
    if d.is_some() {
        return d
    }
    return one_dead(b, init_of, defined)
}

fn list_dead(ops: &List(Operand), init_of: &Dict(String, String), defined: &Dict(String,
        bool)) String? {
    for i in 0..ops.len {
        let d = one_dead(&ops[i], init_of, defined)
        if d.is_some() {
            return d
        }
    }
    return null
}

fn first_undefined_callee(f: &Function, defined: &Dict(String, bool)) String? {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let callee = instrs[i] match {
                Call(c) => c.callee
                // A stored function ADDRESS (a vtable field, a fn value) dangles just like a call
                // if its function was refused - the emitted C names a symbol that does not exist.
                Store(s) => s.value match {
                    FuncRef(n) => n
                    _ => ""
                }
                _ => ""
            }
            if callee.len > 0 {
                if defined.get(callee).is_none() {
                    return Some(callee)
                }
            }
        }
    }
    return null
}

// Lower `ast_module`'s supported functions into the existing `m`.
fn lower_into(m: &IrModule, ctx: &LowerCtx, ast_module: &Module, fqn: String) {
    for &d in ast_module.decls {
        d.* match {
            Function(fd) => lower_decl(m, ctx, &fd, fqn)
            _ => {}
        }
    }
}

// Whether module `i` is in the demand set. No list means a total demand - every module lowers.
fn module_demanded(demanded: &List(bool)?, i: usize) bool {
    if demanded.is_none() {
        return true
    }
    const flags = demanded.unwrap()
    if i >= flags.len {
        return true
    }
    return flags[i]
}

// Only the body-less `#foreign` declarations of an undemanded module: they name global link-time
// symbols any demanded body may call without an import.
fn lower_foreign_decls(m: &IrModule, ctx: &LowerCtx, ast_module: &Module, fqn: String) {
    for &d in ast_module.decls {
        d.* match {
            Function(fd) => {
                if fd.body.is_none() {
                    lower_decl(m, ctx, &fd, fqn)
                }
            }
            _ => {}
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Module-level constants (M11 globals)
//
// Each const becomes an aligned zero-initialized byte global plus a synthesized nullary init
// function that lowers the initializer and stores it - `wire_const_inits` calls every init at the
// top of `main`, so vtables of function pointers and cross-global addresses need no
// static-initializer support in the C emitter. A const whose initializer refuses gets NO global and
// NO `ctx.consts` entry: its readers refuse, and the program stays "absent, never silently wrong".
// ─────────────────────────────────────────────────────────────────────────

fn lower_consts(m: &IrModule, ctx: &LowerCtx, ast_module: &Module) {
    for &d in ast_module.decls {
        d.* match {
            Const(cd) => lower_const_decl(m, ctx, &cd)
            _ => {}
        }
    }
}

// The shape behind a handle - lowering-side shorthand.
fn tn(ctx: &LowerCtx, t: Ty) TyNode {
    return ctx.it.node(t)
}

fn tyit(ctx: &LowerCtx) &TypeInterner {
    return ctx.it
}

fn lower_const_decl(m: &IrModule, ctx: &LowerCtx, cd: &ConstDecl) {
    // The decl's own RtConst target names its FQN (recorded by check_constant_init) - the key every
    // read site cites.
    let fqn_opt: String? = null
    ctx_target(ctx, node_id_of(cd.span)) match {
        Some(t) => t match {
            RtConst(f) => fqn_opt = Some(f)
            _ => {}
        }
        None => {}
    }
    if fqn_opt.is_none() {
        return
    }
    let fqn = fqn_opt.unwrap()
    let tyo = ctx_type(ctx, node_id_of(expr_span(&cd.value)))
    if tyo.is_none() {
        m.skip_notes.push($"{fqn}: const initializer unchecked")
        return
    }
    let t = tyo.unwrap()
    if !ty_concrete(tyit(ctx), t) {
        m.skip_notes.push($"{fqn}: const type not concrete")
        return
    }
    let lay = layout_of(tyit(ctx), t, &ctx.result.nominals, ctx.allocator)
    let gsym = park_sym(ctx, const_symbol("__fconst_", fqn, ctx.allocator))
    let isym = park_sym(ctx, const_symbol("__finit_", fqn, ctx.allocator))

    let fb = function(isym, null, ctx.allocator)
    let env = new_env(ctx.allocator)
    let cur = fb.entry()
    ctx.blocked = false
    ctx.blocked_note = null
    ctx.blocked_subject = null
    let v = lower_expr(ctx, &cur, &env, &cd.value)
    if is_by_ref(ctx, &t) {
        cur.memcpy(Operand.GlobalRef(gsym), v, Operand.IntConst(lay.size as i64))
    } else {
        cur.store(ir_of(ctx, t), v, Operand.GlobalRef(gsym))
    }
    cur.ret_void()
    env.deinit()
    if ctx.blocked {
        m.skipped.push(isym)
        m.skip_notes.push($"{fqn}: const initializer refused")
        fb.deinit()
        return
    }
    m.add_function(fb.finish())
    m.add_global(Global { name = gsym, size = lay.size as u64, align = lay.align as u64,
        init_bytes = null })
    ctx.consts.set(fqn, ConstInfo { sym = gsym, init_sym = isym, ty = t })
    ctx.const_inits.push(isym)
}

// `prefix` + the escaped FQN. The prefix keeps const globals and their init functions out of the
// function-symbol namespace (a const `m.NAME` would otherwise collide with a nullary `fn NAME` in
// module `m`).
fn const_symbol(prefix: String, fqn: String, allocator: &Allocator?) OwnedString {
    let sb = string_builder(prefix.len + fqn.len + 8, allocator)
    defer sb.deinit()
    sb.append(prefix)
    append_module_path(&sb, fqn)
    return sb.to_string()
}

// Park an owned symbol string; the returned view stays valid because an OwnedString's heap bytes do
// not move when the list grows.
fn park_sym(ctx: &LowerCtx, s: OwnedString) String {
    let v = s.as_view()
    ctx.owned_syms.push(s)
    return v
}

// Call every SURVIVING const init at the top of `main`, in registration order, before any user
// instruction. Runs after the drop pass: an init that died there already took every reader of its
// const with it, so skipping its call cannot leave a live read of zeroed memory.
fn wire_const_inits(m: &IrModule, ctx: &LowerCtx) {
    if ctx.const_inits.len == 0 {
        return
    }
    let live: Set(String) = set(ctx.allocator)
    for i in 0..m.functions.len { live.add(m.functions[i].name) }
    for i in 0..m.functions.len {
        if !(m.functions[i].name == "main") {
            continue
        }
        let old = m.functions[i].blocks[0].instrs
        let merged: List(Instr) = list(old.len + ctx.const_inits.len, ctx.allocator)
        for k in 0..ctx.const_inits.len {
            if !live.contains(ctx.const_inits[k]) {
                continue
            }
            let args: List(Operand) = list(0, ctx.allocator)
            let var_types: List(IrType) = list(0, ctx.allocator)
            let no_result: u32? = null
            let no_ty: IrType? = null
            merged.push(Instr.Call(CallInstr {
                result = no_result,
                result_ty = no_ty,
                callee = ctx.const_inits[k],
                args = args,
                variadic_arg_types = var_types,
            }))
        }
        merged.push_all(old.as_slice())
        set_instrs(&m.functions[i].blocks[0], merged)
        live.deinit()
        return
    }
    live.deinit()
}

// The lowered global for a const read, loaded per its declared type. An aggregate's value is the
// global's address; a scalar loads through it.
fn read_const(ctx: &LowerCtx, bb: &BlockBuilder, fqn: String, want: &Ty) Operand {
    let ci = ctx.consts.get(fqn)
    if ci.is_none() {
        return unlowerable_why(ctx, fqn)
    }
    let c = ci.unwrap()
    if !repr_compatible(ctx, &c.ty, want) {
        return unlowerable_why(ctx, "const read repr mismatch")
    }
    if is_by_ref(ctx, &c.ty) {
        return Operand.GlobalRef(c.sym)
    }
    return bb.load(ir_of(ctx, c.ty), Operand.GlobalRef(c.sym))
}

// A function declaration becomes a defined FIR function, or - when it has no body - an external
// declaration so calls to it compile. Both are gated on the signature; `SymbolTable` membership
// mirrors that gate.
fn lower_decl(m: &IrModule, ctx: &LowerCtx, decl: &FunctionDecl, fqn: String) {
    if decl.body.is_none() {
        // Prefer the REGISTERED signature: its types are resolved, so an aggregate parameter or
        // return can be spelled as a C struct. Only variadic foreign declarations are unregistered
        // (C varargs have no FLang signature to check against), and those are scalar-only, so the
        // syntactic path still covers them.
        let fd = foreign_from_sig(m, ctx, decl)
        if fd.is_some() {
            m.add_foreign(fd.unwrap())
            return
        }
        let syn = foreign_decl_of(decl, ctx.allocator)
        if syn.is_some() {
            m.add_foreign(syn.unwrap())
        }
        return
    }
    lower_function(m, ctx, decl)
}

// A body-less declaration as an external symbol, built from the signature the symbol table
// registered. Null when the declaration is not registered (a variadic foreign fn) - the caller
// falls back to the syntactic form.
fn foreign_from_sig(m: &IrModule, ctx: &LowerCtx, decl: &FunctionDecl) ForeignDecl? {
    let id = ctx.syms.decl_fn_id(decl)
    if id.is_none() {
        return null
    }
    if !ctx.syms.is_foreign(id.unwrap()) {
        return null
    }
    let sig_opt = ctx.syms.sig_of(id.unwrap())
    if sig_opt.is_none() {
        return null
    }
    let sig = sig_opt.unwrap()

    // An aggregate the backend cannot spell must sink the WHOLE declaration. Degrading it to `ptr`
    // would emit `extern double f(void*)` for a C function that takes a struct by value - it
    // compiles, links, and passes the wrong thing. No extern means calls refuse instead.
    for i in 0..sig.params.len {
        if crosses_unspellable(ctx, &sig.params[i]) {
            return null
        }
    }
    if crosses_unspellable(ctx, &sig.ret) {
        return null
    }

    let ptys: List(IrType) = list(sig.params.len, ctx.allocator)
    for i in 0..sig.params.len {
        ptys.push(foreign_ir_of(m, ctx, &sig.params[i]))
    }
    let ret: IrType? = if sig.ret == TY_VOID or sig.ret == TY_NEVER {
        null
    } else {
        Some(foreign_ir_of(m, ctx, &sig.ret))
    }
    return Some(ForeignDecl {
        name = decl.name,
        return_ty = ret,
        param_types = ptys,
        variadic = false,
        cc = CallConv.C,
    })
}

// An aggregate that would have to cross by value but has no C definition this backend can write.
// References and niche options are not aggregates by representation and cross fine.
fn crosses_unspellable(ctx: &LowerCtx, ty: &Ty) bool {
    if !is_aggregate(tyit(ctx), ty.*) {
        return false
    }
    if niche_optional(ctx, ty) {
        return false
    }
    return agg_type_of(ctx, ty).is_none()
}

// A type as it crosses a foreign boundary: an ABI-safe aggregate becomes a by-value C struct
// (registered on the module so the backend defines it), everything else keeps its ordinary FIR
// representation.
fn foreign_ir_of(m: &IrModule, ctx: &LowerCtx, ty: &Ty) IrType {
    let agg = register_agg(m, ctx, ty)
    if agg.is_some() {
        return IrType.Agg(agg.unwrap())
    }
    return ir_of(ctx, ty.*)
}

// A body-less declaration as an external symbol. Null when a parameter or the return type is
// outside the subset - the backend can't spell it, and nothing can call it. The variadic tail is
// dropped from `param_types` and flagged, matching C's `(fixed..., ...)` shape.
fn foreign_decl_of(decl: &FunctionDecl, allocator: &Allocator?) ForeignDecl? {
    let ret: IrType? = null
    if decl.return_type.is_some() {
        let rt = decl.return_type.unwrap()
        // `never` (e.g. `#foreign fn exit(code: i32) never`) yields no value - the extern declares
        // as void, same as no return type.
        if !type_expr_is_never(&rt) {
            let r = type_expr_to_ir(&rt)
            if r.is_none() {
                return null
            }
            ret = r
        }
    }
    let ptys: List(IrType) = list(decl.params.len, allocator)
    let variadic = false
    for &p in decl.params {
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
    return Some(ForeignDecl {
        name = decl.name,
        return_ty = ret,
        param_types = ptys,
        variadic = variadic,
        cc = CallConv.C,
    })
}

// Lower one function definition and append it to `m`. Returns without emitting when the signature
// uses a type this milestone can't lower, or when the symbol pre-pass didn't register one - the two
// gates are the same test, so a skipped definition is also an uncallable one.
fn lower_function(m: &IrModule, ctx: &LowerCtx, decl: &FunctionDecl) {
    // A generic TEMPLATE has no single body to emit: `List($T)` is a different layout per `T`. Its
    // instantiations lower separately - see `lower_specializations` - and the template itself never
    // does.
    //
    // This gate is separate from `type_expr_to_ir` on purpose: a `$T` behind a reference
    // (`&List($T)`) lowers to a plain pointer, so the scalar gate waves it straight through.
    if declares_generic(decl) {
        return
    }

    let fid = ctx.syms.decl_fn_id(decl)
    if fid.is_none() {
        return
    }
    let sym_opt = ctx.syms.lookup_symbol(fid.unwrap())
    if sym_opt.is_none() {
        return
    }
    let sym = sym_opt.unwrap()
    let sig_opt = ctx.syms.sig_of(fid.unwrap())
    if sig_opt.is_none() {
        return
    }
    let sig = sig_opt.unwrap()
    lower_function_body(m, ctx, decl, sym, &sig)
}

// Lower every specialization the checker instantiated (M10): the template's declaration re-lowers
// once per concrete signature, reading node types / targets / operators through the instantiation's
// overlay, under a symbol mangled from the concrete parameter AND return types (return included
// because a return-only-polymorphic template's instantiations share every parameter token).
fn lower_specializations(m: &IrModule, ctx: &LowerCtx, skip_modules: &Set(String)? = null) {
    // Two specs can settle to the SAME final signature when their signatures entered instantiation
    // with callable-slot vars (RFC-014 lambdas through `$F`) - their symbols then collide; emit the
    // first and skip the twins.
    let emitted: Set(String) = set(ctx.allocator)
    for i in 0..(ctx.result.specializations.next_id as usize) {
        let found = ctx.result.specializations.find(i as u32)
        if found.is_none() {
            continue
        }
        let s = found.unwrap()
        if s.decl.body.is_none() {
            continue
        }
        if skip_modules.is_some() and skip_modules.unwrap().contains(s.module) {
            continue
        }
        let sym = ctx.syms.spec_symbol(s.id)
        let sig = ctx.syms.spec_sig(s.id)
        if sym.is_none() {
            continue
        }
        if sig.is_none() {
            continue
        }
        if emitted.contains(sym.unwrap()) {
            continue
        }
        emitted.add(sym.unwrap())
        let g = sig.unwrap()
        ctx.overlay = Some(&s.overlay)
        lower_function_body(m, ctx, &s.decl, sym.unwrap(), &g)
        ctx.overlay = null
    }
    emitted.deinit()
}

// Emit every enqueued lambda body. Index-based on purpose: emitting one can enqueue lambdas nested
// inside it.
fn lower_pending_lambdas(m: &IrModule, ctx: &LowerCtx) {
    let i: usize = 0
    while i < ctx.pending_lambdas.len {
        // Copy out: the list may grow (and reallocate) during emission.
        let pl = ctx.pending_lambdas[i]
        i = i + 1
        let saved = ctx.overlay
        ctx.overlay = pl.overlay
        emit_lambda_fn(m, ctx, &pl)
        ctx.overlay = saved
    }
}

fn emit_lambda_fn(m: &IrModule, ctx: &LowerCtx, pl: &PendingLambda) {
    let empty_dirs: List(DeclAttribute) = list(0, ctx.allocator)
    let decl = FunctionDecl {
        span = pl.lam.span,
        is_pub = false,
        directives = empty_dirs,
        name = pl.info.symbol.as_view(),
        params = pl.lam.params,
        return_type = pl.lam.return_type,
        body = Some(pl.lam.body),
    }
    let sig_params: List(Ty) = list(pl.info.params.len, ctx.allocator)
    sig_params.push_all(pl.info.params.as_slice())
    let sig = FnSig { params = sig_params, ret = pl.info.ret }
    if pl.info.captures.len == 0 {
        lower_function_body(m, ctx, &decl, pl.info.symbol.as_view(), &sig)
        return
    }
    let cid = pl.info.closure_id.unwrap()
    let no_args: List(Ty) = list(0, ctx.allocator)
    let cty = ctx.it.nominal_of(cid, &no_args)
    no_args.deinit()
    lower_function_body(m, ctx, &decl, pl.info.symbol.as_view(), &sig,
        Some(LoweredClosure { ty = cty, captures = &pl.info.captures }))
}

fn bind_closure_captures(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, c: &LoweredClosure,
    self_val: Operand) {
    let target = resolve_struct(ctx, &c.ty, &ctx.result.nominals, ctx.allocator)
    if target.is_none() {
        ctx.blocked = true
        return
    }
    let st = target.unwrap()
    for i in 0..c.captures.len {
        let cap = &c.captures[i]
        let addr = bb.gep(self_val, Operand.IntConst(st.layout.offsets[i] as i64))
        if is_by_ref(ctx, &cap.ty) {
            env.bind_aggregate(cap.name, addr, cap.ty)
        } else {
            env.bind_slot(cap.name, addr, ir_of(ctx, cap.ty), cap.ty)
        }
    }
}

fn lower_function_body(m: &IrModule, ctx: &LowerCtx, decl: &FunctionDecl, sym: String, sig: &FnSig,
    closure: LoweredClosure? = null) {
    // The scheme and the decl are two views of one declaration; a length mismatch is a violated
    // contract, not a case to paper over.
    if sig.params.len != decl.params.len {
        return
    }

    // An aggregate return leaves FIR's return slot empty: the caller passes the destination buffer
    // as a trailing `ptr` parameter (sret) and the function copies into it before each `ret` - see
    // `emit_call`, which is the other half of the convention.
    let ret_agg = is_by_ref(ctx, &sig.ret)
    let returns_value = !(sig.ret == TY_VOID or sig.ret == TY_NEVER)
    let return_ir: IrType? = null
    if returns_value and !ret_agg {
        return_ir = Some(ir_of(ctx, sig.ret))
    }

    let fb = function(sym, return_ir, ctx.allocator)
    let env = new_env(ctx.allocator)
    // A closure op_call takes its environment struct's address as a leading parameter, before the
    // lambda's own parameters (and before the sret slot, mirroring the call-site layout in
    // `lower_callee_value_call`).
    let self_op: Operand? = null
    if closure.is_some() {
        self_op = Some(fb.param(IrType.Ptr))
    }
    let param_ops: List(Operand) = list(decl.params.len + 1, ctx.allocator)
    for i in 0..sig.params.len {
        param_ops.push(fb.param(ir_of(ctx, sig.params[i])))
    }
    let sret_op: Operand? = null
    if ret_agg {
        sret_op = Some(fb.param(IrType.Ptr))
    }

    // `cur` is the block cursor: control flow moves it, so the body's final terminator lands on
    // whatever block lowering ended in, not the entry.
    let cur = fb.entry()
    ctx.blocked = false
    ctx.blocked_note = null
    ctx.blocked_subject = null
    ctx.sret = sret_op
    ctx.ret_size = 0u64
    if ret_agg {
        ctx.ret_size = layout_of(tyit(ctx), sig.ret, &ctx.result.nominals,
            ctx.allocator).size as u64
    }

    // Parameters spill to slots like any other local, so assigning one - or taking its address -
    // needs no special case. An aggregate parameter arrives as a pointer to the caller's value; the
    // callee copies it into its own slot, so mutating a by-value parameter can never write through
    // to the caller (value semantics). The spill is also what makes `&param` inlining-safe: the
    // slot is an ordinary instruction the shim inliner clones with the body, so the spliced copy
    // keeps value semantics with no name resolution involved (the reference inliner's
    // address-of-parameter bug cannot exist here); spills that never escape are mem2reg's to
    // delete, not lowering's to avoid.
    for i in 0..decl.params.len {
        let pty = &sig.params[i]
        if is_by_ref(ctx, pty) {
            let lay = layout_of(tyit(ctx), pty.*, &ctx.result.nominals, ctx.allocator)
            let slot = cur.stack_slot(lay.size as u64, lay.align as u64)
            cur.memcpy(slot, param_ops[i], Operand.IntConst(lay.size as i64))
            env.bind_aggregate(decl.params[i].name, slot, pty.*)
        } else {
            let ir = ir_of(ctx, pty.*)
            let slot = alloc_slot(&cur, ir)
            cur.store(ir, param_ops[i], slot)
            env.bind_slot(decl.params[i].name, slot, ir, pty.*)
        }
    }
    param_ops.deinit()
    // Captured names bind to fields of the closure env - reads project through the caller's struct
    // (captures are read-only, E2112, so aliasing it is safe; no copy).
    if closure.is_some() {
        let c = closure.unwrap()
        bind_closure_captures(ctx, &cur, &env, &c, self_op.unwrap())
    }
    let body = decl.body.unwrap()
    let implicit_ret: Ty? = null
    if returns_value {
        implicit_ret = Some(sig.ret)
    }
    let r = lower_block(ctx, &cur, &env, &body, implicit_ret)
    if !r.terminated {
        if ctx.sret.is_some() {
            // The trailing expression is the return value; copy it into the caller's buffer. No
            // value means the body diverged in a way the checker accepted - return void either way,
            // the signature has no return slot.
            if r.value.is_some() {
                cur.memcpy(ctx.sret.unwrap(), r.value.unwrap(),
                    Operand.IntConst(ctx.ret_size as i64))
            }
            cur.ret_void()
        } else if return_ir.is_none() {
            // A void function DISCARDS its trailing expression's value - the expression is already
            // emitted, for its effects. Returning it instead put `return 0` in a `void` C function,
            // which is what an assignment in trailing position (`self.f = v`) looks like:
            // `lower_assignment` yields the unit placeholder. The checker has the mirror of this
            // rule.
            cur.ret_void()
        } else if r.value.is_some() {
            cur.ret(r.value.unwrap())
        } else {
            // A value function with no return path is a checker error.
            cur.unreachable()
        }
    }
    env.deinit()
    ctx.sret = null

    // TEMPORARY SCAFFOLD (see `unlowerable`): the body used something outside the subset. Emitting
    // it anyway would bake placeholder zeros into a function that still links and runs.
    if ctx.blocked {
        m.skipped.push(sym)
        let why = ctx.blocked_note match {
            Some(w) => w
            None => "unsupported construct"
        }
        ctx.blocked_subject match {
            Some(subj) => m.skip_notes.push($"{sym}: body refused ({why} `{subj}`)")
            None => m.skip_notes.push($"{sym}: body refused ({why})")
        }
        fb.deinit()
        return
    }
    m.add_function(fb.finish())
}

// What lowering a block produced: whether it ended in a terminator (so the caller must not append
// one of its own - `set_terminator` overwrites) and the value of its trailing expression, if any.
type BlockResult = struct {
    terminated: bool
    value: Operand?
}

// Lower a block's statements then its trailing expression. The block's own scope is popped on the
// way out, so bindings introduced here do not leak into the code that follows. Each block is also a
// defer scope: on normal fall-through its defers fire (LIFO) after the trailing value is computed;
// on a terminated path they already fired at the terminator, so the scope only pops its stack
// slots.
fn lower_block(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, block: &BlockExpr,
    implicit_ret: Ty? = null) BlockResult {
    let scope = env.mark()
    ctx.defer_marks.push(ctx.defers.len)
    let r = BlockResult { terminated = false, value = null }
    // A value-returning function body whose last statement is an expression returns it, even when
    // the projector did not promote it to `trailing`: `if` / `match` in statement position land in
    // the block unwrapped (`project_expr_as_stmt`), so `fn max(a, b) i32 { if a > b { a } else { b
    // } }` has no trailing at all. Reference parity - the reference applies the same rule at
    // lowering time (HmAstLowering, "the last expression-statement in a non-void function is an
    // implicit return value") and, like it, this is a LOWERING rule only: statement-position arms
    // are not made to join during checking.
    let last_is_value = false
    if implicit_ret.is_some() and block.trailing.is_none() and block.stmts.len > 0 {
        block.stmts[block.stmts.len - 1] match {
            Expression(_) => last_is_value = true
            _ => {}
        }
    }
    let n_stmts = if last_is_value { block.stmts.len - 1 } else { block.stmts.len }
    for i in 0..n_stmts {
        if lower_stmt(ctx, bb, env, &block.stmts[i]) {
            r.terminated = true
            pop_defer_scope(ctx, bb, env, true)
            env.release(scope)
            return r
        }
    }
    if last_is_value {
        let ls = &block.stmts[block.stmts.len - 1]
        ls.* match {
            Expression(es) => {
                // A statement-position `if` records as Void by design (`check_if_stmt` does not
                // force its arms to join - reference parity), so the join type has to come from the
                // return type here, exactly as the reference passes `retIrType` into its
                // last-statement `LowerExpression`.
                es.expr match {
                    If(ife) => r.value = Some(lower_if(ctx, bb, env, &ife, implicit_ret))
                    _ => r.value = Some(lower_expr(ctx, bb, env, &es.expr))
                }
            }
            _ => {}
        }
        pop_defer_scope(ctx, bb, env, false)
        env.release(scope)
        return r
    }
    if block.trailing.is_some() {
        let e = block.trailing.unwrap()
        let v = lower_expr(ctx, bb, env, e)
        // The scope's defers fire between the trailing value's computation and its use by the
        // enclosing code (spec 4.1: value first, then defers). A scalar is an SSA value and immune;
        // an aggregate is an address a defer could write through (`{ defer x.f = 9; x }`), so it is
        // copied out before the flush - only when this scope actually has defers pending.
        let mark = ctx.defer_marks[ctx.defer_marks.len - 1]
        if ctx.defers.len > mark {
            let ty = node_ty(ctx, expr_span(e))
            if is_by_ref(ctx, &ty) {
                let lay = layout_of(tyit(ctx), ty, &ctx.result.nominals, ctx.allocator)
                let slot = bb.stack_slot(lay.size as u64, lay.align as u64)
                bb.memcpy(slot, v, Operand.IntConst(lay.size as i64))
                v = slot
            }
        }
        r.value = Some(v)
    }
    pop_defer_scope(ctx, bb, env, false)
    env.release(scope)
    return r
}

// Close the innermost defer scope: emit its pending defers unless the path already terminated (the
// terminator's own flush covered them), then drop them from the stack.
fn pop_defer_scope(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, terminated: bool) {
    let mark = ctx.defer_marks.pop().unwrap()
    if !terminated {
        emit_defers_down_to(ctx, bb, env, mark)
    }
    while ctx.defers.len > mark {
        let _d = ctx.defers.pop()
    }
}

// Emit every pending defer above `target`, innermost first (LIFO), WITHOUT popping - `return` /
// `break` / `continue` / `?` traverse scopes they do not close; each block pops its own suffix.
fn emit_defers_down_to(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, target: usize) {
    let prev = ctx.flushing
    ctx.flushing = true
    let i = ctx.defers.len
    while i > target {
        i = i - 1
        let _v = lower_expr(ctx, bb, env, &ctx.defers[i])
    }
    ctx.flushing = prev
}

// A block in expression position: its value, or the placeholder when it yields nothing.
fn lower_block_value(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, block: &BlockExpr) Operand {
    let r = lower_block(ctx, bb, env, block)
    if r.value.is_some() {
        return r.value.unwrap()
    }
    return Operand.IntConst(0)
}

// Returns whether the statement emitted a block terminator.
fn lower_stmt(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, stmt: &Stmt) bool {
    stmt.* match {
        Return(r) => {
            lower_return(ctx, bb, env, &r)
            return true
        }
        Let(l) => lower_let(ctx, bb, env, &l)
        Expression(e) => {
            let _u = lower_expr(ctx, bb, env, &e.expr)
        }
        While(w) => lower_while(ctx, bb, env, &w)
        Loop(l) => lower_loop(ctx, bb, env, &l)
        For(f) => lower_for(ctx, bb, env, &f)
        Break(_) => return lower_jump(ctx, bb, env, true)
        Continue(_) => return lower_jump(ctx, bb, env, false)

        // `defer expr` - registered on the schedule; it fires at the enclosing scope's exit and at
        // every escaping jump that passes through it (`return`, `break`, `continue`, `?`). The
        // pushed node is a copy; its children live in the module's arena.
        Defer(d) => ctx.defers.push(d.expr)

        // Not lowered yet - named rather than caught by a wildcard, so adding a `Stmt` variant is a
        // compile error here instead of a silent skip.

        // `#if cond { … } else { … }` - the checker validated the
        // condition; re-evaluate against the same host context and splice the active branch's
        // statements in place.
        IfDirective(ifd) => {
            eval_condition(&ctx.comptime, &ifd.condition) match {
                Active(active) => {
                    const stmts: &List(Stmt) = if active { &ifd.then_stmts } else { &ifd.else_stmts }
                    for i in 0..stmts.len {
                        if lower_stmt(ctx, bb, env, &stmts[i]) {
                            return true
                        }
                    }
                }
                Invalid(_) => { let _u = unlowerable(ctx) }
            }
        }
    }
    return false
}

// `break` / `continue`. Outside a loop both are checker errors; lowering emits nothing rather than
// branching to a label that does not exist. The jump escapes every scope opened since loop entry,
// so their defers fire first (the scopes still pop their own stack suffix - see
// `emit_defers_down_to`).
fn lower_jump(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, is_break: bool) bool {
    // An escape from inside a deferred expression would re-enter the flush that is emitting it -
    // refuse (see `LowerCtx.flushing`).
    if ctx.flushing {
        let _u = unlowerable(ctx)
        return false
    }
    if ctx.loops.len == 0 {
        return false
    }
    let frame = ctx.loops[ctx.loops.len - 1]
    emit_defers_down_to(ctx, bb, env, frame.defer_depth)
    if is_break {
        bb.br(frame.exit)
    } else {
        bb.br(frame.latch)
    }
    return true
}

// `return expr` evaluates `expr` FIRST, then fires every active defer (LIFO), then transfers - spec
// 4.1 "Defer ordering on return". The value is materialized before the flush: a scalar is an SSA
// value, an aggregate is already copied into the caller's sret buffer.
fn lower_return(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, r: &ReturnStmt) {
    // A `return` inside a deferred expression would re-enter the flush that is emitting it - refuse
    // (see `LowerCtx.flushing`).
    if ctx.flushing {
        let _u = unlowerable(ctx)
        bb.ret_void()
        return
    }
    if r.value.is_some() {
        let e = r.value.unwrap()
        let v = lower_expr(ctx, bb, env, &e)
        // An aggregate return value is an address; copy its bytes into the caller's sret buffer and
        // return void - the FIR signature has no return slot for it.
        if ctx.sret.is_some() {
            bb.memcpy(ctx.sret.unwrap(), v, Operand.IntConst(ctx.ret_size as i64))
            emit_defers_down_to(ctx, bb, env, 0)
            bb.ret_void()
            return
        }
        emit_defers_down_to(ctx, bb, env, 0)
        bb.ret(v)
    } else {
        emit_defers_down_to(ctx, bb, env, 0)
        bb.ret_void()
    }
}

// `let name = init` - the local gets a stack slot and the initializer is stored into it. An
// aggregate initializer already produced its own storage, so the name binds to that address instead
// of copying it.
//
// The binding's type comes from the checker, not from the annotation: `let x` with neither
// annotation nor initializer is legal and infers from later use (`let i` then `print_u8(i)` makes
// `i` a `u8`).
//
// The type is unwrapped, not guarded. Inferring every binding is the checker's job and refusing to
// lower an unchecked unit is the driver's (`compile.f::build_program`, gated by
// `project_error_count` in `finish_build`). A missing type here is a violated contract, and
// panicking on it beats inventing one and compiling silently wrong arithmetic.
fn lower_let(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, l: &LetStmt) {
    let ty = ctx_type(ctx, node_id_of(l.span)).unwrap()

    // A binding the checker could not type concretely marks a construct it does not cover yet
    // (today: an array literal with a non-literal repeat count, `[0u8; PAGE_SIZE]`) - refuse the
    // function rather than let the Var reach `ir_of`'s hard failure. This is the subset gate, not a
    // fallback width.
    let unresolved = tyit(ctx).is_var(ty)
    if unresolved {
        let _r = unlowerable(ctx)
        return
    }

    if l.init.is_none() {
        // Zero initialization is the language's guarantee of the variable's first value (spec 4.2),
        // not an obligation to emit this store: it may be dropped wherever the variable is provably
        // written before any read.
        //
        // ponytail: that write-before-read analysis is unwritten, so the store always emits.
        // Correct, just not minimal.
        if is_by_ref(ctx, &ty) {
            // Zero bytes are the zero-initialized value of every aggregate; for `Option`
            // specifically, tag 0 is `None` by declaration order (a documented invariant in
            // core.option).
            let lay = layout_of(tyit(ctx), ty, &ctx.result.nominals, ctx.allocator)
            let slot = bb.stack_slot(lay.size as u64, lay.align as u64)
            bb.memset(slot, Operand.IntConst(0), Operand.IntConst(lay.size as i64))
            env.bind_aggregate(l.name, slot, ty)
            return
        }
        let zero_ir = ir_of(ctx, ty)
        let zero_slot = alloc_slot(bb, zero_ir)
        bb.store(zero_ir, Operand.IntConst(0), zero_slot)
        env.bind_slot(l.name, zero_slot, zero_ir, ty)
        return
    }

    let e = l.init.unwrap()
    // Adapted like a call argument: an array-typed initializer bound at a slice type decays to a
    // `{ptr, len}` view (`let xs: i32[] = [...]`) - binding the raw array bytes as a slice read a
    // garbage length.
    let v = lower_adapted(ctx, bb, env, &e, &ty)
    if is_by_ref(ctx, &ty) {
        // The initializer's operand is an address. When it points at an existing place - another
        // local, a field inside one - binding it directly would alias: `let a = b` then `a.x = 1`
        // must not write `b.x`. The local gets its own storage and a copy (value semantics). A
        // FRESH temporary (a struct literal's slot, a call's sret buffer) has no other name, so the
        // binding takes it over and the copy is elided.
        if !init_is_fresh(&e) {
            let lay = layout_of(tyit(ctx), ty, &ctx.result.nominals, ctx.allocator)
            let slot = bb.stack_slot(lay.size as u64, lay.align as u64)
            bb.memcpy(slot, v, Operand.IntConst(lay.size as i64))
            env.bind_aggregate(l.name, slot, ty)
            return
        }
        env.bind_aggregate(l.name, v, ty)
        return
    }
    let ir = ir_of(ctx, ty)
    let slot = alloc_slot(bb, ir)
    bb.store(ir, v, slot)
    env.bind_slot(l.name, slot, ir, ty)
}

// Whether an aggregate initializer's result is storage no other name can reach: a struct literal
// builds into its own slot, a direct call returns through a fresh sret buffer, and `null`
// zero-fills a fresh slot. An identifier, member, index or deref hands back an EXISTING place; an
// `if`/`match`/block value may forward one of those. `Call` is safe even for the ref-form index
// operator's address result because that shape only arises from `Index`, not `Call`.
fn init_is_fresh(expr: &Expr) bool {
    return expr.* match {
        StructLit(_) => true
        Call(_) => true
        Lit(_) => true
        // The desugared block's value is its trailing `to_string()` call's sret buffer - fresh by
        // the `Call` rule above.
        InterpolatedString(_) => true
        _ => false
    }
}

// Expressions

fn lower_expr(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, expr: &Expr) Operand {
    return expr.* match {
        Lit(l) => lower_literal(ctx, bb, &l)
        Identifier(id) => lower_identifier(ctx, bb, env, &id)
        Assignment(a) => lower_assignment(ctx, bb, env, &a)
        AddressOf(a) => lower_address_of(ctx, bb, env, &a)
        Dereference(d) => lower_deref(ctx, bb, env, &d)
        Binary(b) => lower_binary(ctx, bb, env, &b)
        Unary(u) => lower_unary(ctx, bb, env, &u)
        StructLit(s) => lower_struct_lit(ctx, bb, env, &s)
        MemberAccess(m) => lower_member(ctx, bb, env, &m)
        Call(c) => lower_call(ctx, bb, env, &c)
        If(f) => lower_if(ctx, bb, env, &f)
        Block(b) => lower_block_value(ctx, bb, env, &b)
        Match(mt) => lower_match(ctx, bb, env, &mt)

        // Not lowered yet - named rather than caught by a wildcard, so adding an `Expr` variant is
        // a compile error here instead of a silent refusal that looks like a deliberate one.

        Index(ix) => lower_index(ctx, bb, env, &ix)
        Cast(c) => lower_cast(ctx, bb, env, &c)
        ArrayLit(al) => lower_array_lit(ctx, bb, env, &al)
        TupleLit(tl) => lower_tuple_lit(ctx, bb, env, &tl)
        // `$"…"` - the checker desugared it to a StringBuilder block
        // (RFC-004); replay that block. No recorded desugar (a `$sb"…"`
        // whose target wasn't an identifier) refuses.
        InterpolatedString(is) => lower_interpolation(ctx, bb, env, &is)
        NullPropagation(np) => lower_null_propagation(ctx, bb, env, &np)
        Coalesce(co) => lower_coalesce(ctx, bb, env, &co)
        Try(tr) => lower_try(ctx, bb, env, &tr)
        // `a..b` as a value: the `Range(T)` struct the slicing op_index overloads take (M11). `for`
        // headers still handle their own range directly (see `lower_for_range`).
        Range(rg) => lower_range_value(ctx, bb, env, &rg)
        Lambda(lam) => lower_lambda(ctx, bb, env, &lam)
        // A parse or projection failure. Already diagnosed upstream; refusing the function keeps a
        // recovered AST from reaching the backend. Not part of the milestone scaffold - this one
        // stays.
        Error(_) => {
            ctx.blocked = true
            Operand.IntConst(0)
        }
    }
}

// `$"…"` / `$sb"…"` - lower the checker-recorded StringBuilder desugar
// (see checker.f::check_interpolation). The block is ordinary AST whose nodes carry
// checker-recorded types and call picks under synthetic ids, so the normal block path does all the
// work; its value is the `to_string()` result (an aggregate address) for the owned form, the
// placeholder for the void into-builder form.
fn lower_interpolation(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env,
    is: &InterpolatedStringExpr) Operand {
    let blk = ctx_desugar(ctx, node_id_of(is.span))
    if blk.is_none() {
        return unlowerable_why(ctx, "interpolation without desugar")
    }
    return lower_block_value(ctx, bb, env, blk.unwrap())
}

// Control flow (M3)
//
// FIR is block-based with block parameters, so a construct that joins two paths passes its value
// along the edges instead of writing to a stack slot: no allocas, no phi nodes, and nothing to
// promote later. Loops use the same mechanism for the induction variable.
//
// A local mutated across a back edge would need a slot (or a loop-carried block parameter the walk
// does not compute yet), so assignment stays out of the subset - see `lower_place`. A loop reading
// an outer binding is fine: that value dominates the loop.

// `if` in expression position. The join block takes the result as a block parameter and each arm
// passes its own; an arm that terminated (returned, broke) contributes no edge. An `if` with no
// `else` cannot yield a value, whatever the checker recorded for the node.
fn lower_if(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ife: &IfExpr, want: Ty? = null) Operand {
    let ty = node_ty(ctx, ife.span)
    // `want` is the type the CONSUMER needs (the enclosing function's return type, for a body's
    // implicit-return `if`). A statement- position `if` is recorded as Void, so without it the join
    // would carry no value.
    if want.is_some() and !yields_value(ctx, ty) {
        ty = want.unwrap()
    }
    let yields = yields_value(ctx, ty) and !is_no_else(&ife.else_branch)
    // An aggregate-valued `if` joins the arms' ADDRESSES; the consumer copies (a `let` binding, a
    // store, a callee) so the arm slots' lifetimes - function-long, like all stack slots - are
    // never a problem.
    let ir = ir_of(ctx, ty)

    let cond = lower_expr(ctx, bb, env, ife.condition)

    let fb = bb.fb
    let then_bb = fb.block(fb.fresh_label("then"))
    let else_bb = fb.block(fb.fresh_label("else"))
    let join = if yields {
        fb.block(fb.fresh_label("join"), ir)
    } else {
        fb.block(fb.fresh_label("join"))
    }
    bb.br_if(cond, then_bb.label(), else_bb.label())

    bb.move_to(&then_bb)
    let tr = lower_block(ctx, bb, env, &ife.then_branch)
    join_from(ctx, bb, join.label(), yields, &tr)

    bb.move_to(&else_bb)
    let er = lower_else(ctx, bb, env, &ife.else_branch)
    join_from(ctx, bb, join.label(), yields, &er)

    bb.move_to(&join)
    if yields {
        return join.param(0)
    }
    return Operand.IntConst(0)
}

// Branch an arm's fall-through edge into the join block, carrying its value when the `if` yields
// one. A terminated arm contributes no edge.
fn join_from(ctx: &LowerCtx, bb: &BlockBuilder, label: String, yields: bool, r: &BlockResult) {
    if r.terminated {
        return
    }
    if !yields {
        bb.br(label)
        return
    }
    bb.br_arg(label, unwrap_or(r.value, Operand.IntConst(0)))
}

fn lower_else(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, eb: &ElseBranch) BlockResult {
    return eb.* match {
        Block(b) => lower_block(ctx, bb, env, &b)
        If(i) => BlockResult { terminated = false, value = Some(lower_if(ctx, bb, env, i)) }
        NoElse => BlockResult { terminated = false, value = null }
    }
}

fn is_no_else(eb: &ElseBranch) bool {
    return eb.* match {
        NoElse => true
        _ => false
    }
}

// Whether a node in expression position produces a usable value. `Never` and `Error` do not:
// nothing reaches the join through them. A `Var` does not either: since M10 every consumed value is
// concrete, so a still-free node type means NOTHING consumed the value (a statement- position match
// whose arms all diverge, say) - there is no read to feed, and allocating a slot for it would need
// a guessed width.
fn yields_value(ctx: &LowerCtx, ty: Ty) bool {
    if ty == TY_VOID or ty == TY_NEVER or ty == TY_ERROR {
        return false
    }
    return !tyit(ctx).is_var(ty)
}

// `while cond { body }` - the head re-evaluates the condition, so it is also the `continue` target.
fn lower_while(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, w: &WhileStmt) {
    let fb = bb.fb
    let head = fb.block(fb.fresh_label("while_head"))
    let body = fb.block(fb.fresh_label("while_body"))
    let exit = fb.block(fb.fresh_label("while_exit"))

    bb.br(head.label())
    bb.move_to(&head)
    let cond = lower_expr(ctx, bb, env, w.condition)
    bb.br_if(cond, body.label(), exit.label())

    bb.move_to(&body)
    ctx.loops.push(LoopFrame { latch = head.label(), exit = exit.label(),
        defer_depth = ctx.defers.len })
    let r = lower_block(ctx, bb, env, &w.body)
    let _f = ctx.loops.pop()
    if !r.terminated {
        bb.br(head.label())
    }

    bb.move_to(&exit)
}

// `loop { body }` - exits only through `break` or `return`, so the exit block is reachable only
// from a `break`.
fn lower_loop(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, l: &LoopStmt) {
    let fb = bb.fb
    let head = fb.block(fb.fresh_label("loop_head"))
    let exit = fb.block(fb.fresh_label("loop_exit"))

    bb.br(head.label())
    bb.move_to(&head)
    ctx.loops.push(LoopFrame { latch = head.label(), exit = exit.label(),
        defer_depth = ctx.defers.len })
    let r = lower_block(ctx, bb, env, &l.body)
    let _f = ctx.loops.pop()
    if !r.terminated {
        bb.br(head.label())
    }

    bb.move_to(&exit)
}

// `for i in a..b { body }` - the induction variable is the head block's parameter, so it needs no
// stack slot. The latch (which advances it) is the `continue` target, not the head.
//
// Only bounded integer ranges lower. Any other iterable needs the iterator protocol, which is
// outside this milestone; the loop is skipped, matching how out-of-subset expressions lower to a
// placeholder.
fn lower_for(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, f: &ForStmt) {
    // The range is matched into a reference rather than copied out: an optional-of-reference field
    // (`start: &Expr?`) read off a by-value local mis-lowers in the reference compiler
    // (docs/known-issues.md).
    f.iterable.* match {
        Range(r) => lower_for_range(ctx, bb, env, f, &r)
        _ => lower_for_iter(ctx, bb, env, f)
    }
}

// `for x in xs` over the iterator protocol (M11): call the checker's recorded `iter` pick once (the
// pick sits on the BODY block node), then loop `next(&state)` (recorded on the FOR node), testing
// the returned Option's discriminant. Each iteration copies the payload into the loop variable's
// own slot (value semantics).
fn lower_for_iter(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, f: &ForStmt) {
    let iop = ctx_operator(ctx, node_id_of(f.body.span))
    let nop = ctx_operator(ctx, node_id_of(f.span))
    if iop.is_none() or nop.is_none() {
        let _u = unlowerable_why(ctx, "for over an iterator (no protocol picks)")
        return
    }
    let io = iop.unwrap()
    let no = nop.unwrap()
    let isym = op_symbol(ctx, &io)
    let isig = op_sig(ctx, &io)
    let nsym = op_symbol(ctx, &no)
    let nsig = op_sig(ctx, &no)
    if isym.is_none() or isig.is_none() {
        let _u = unlowerable_why(ctx, "for-iter without iter symbol")
        return
    }
    if nsym.is_none() or nsig.is_none() {
        let _u = unlowerable_why(ctx, "for-iter without next symbol")
        return
    }
    let ig = isig.unwrap()
    let ng = nsig.unwrap()
    if ig.params.len != 1 {
        let _u = unlowerable(ctx)
        return
    }
    if ng.params.len != 1 {
        let _u = unlowerable(ctx)
        return
    }

    // The Option geometry of `next`'s return, and the element type.
    let t = resolve_enum(ctx, &ng.ret, &ctx.result.nominals)
    if t.is_none() {
        let _u = unlowerable_why(ctx, "for-iter next() not an Option")
        return
    }
    let et = t.unwrap()
    if et.args.len != 1 {
        let _u = unlowerable(ctx)
        return
    }
    let ety = et.args[0]
    let ol = enum_layout(tyit(ctx), &et.def, &et.args, &ctx.result.nominals, ctx.allocator)

    // `iter(&xs)`: an aggregate iterable's value IS its address; a reference value is already the
    // pointer the parameter wants. A fixed array decays into the `{ptr, len}` view `iter(&T[])`
    // takes (`lower_adapted` against the parameter's pointee).
    let iter_recv_ty = peel_ref(ctx, ig.params[0])
    let recv = lower_adapted(ctx, bb, env, f.iterable, &iter_recv_ty)
    let iargs: List(Operand) = list(2, ctx.allocator)
    iargs.push(recv)
    let state = emit_call(ctx, bb, isym.unwrap(), &ig, iargs)
    // `next` takes the state as its parameter declares: a self-iterator (`iter -> &State`,
    // `next(&State)`) passes it unchanged; otherwise the state's address (an aggregate's value IS
    // one; a scalar spills).
    let state_addr = state
    if !repr_compatible(ctx, &ig.ret, &ng.params[0]) {
        if !is_by_ref(ctx, &ig.ret) {
            let sir = ir_of(ctx, ig.ret)
            let slot = alloc_slot(bb, sir)
            bb.store(sir, state, slot)
            state_addr = slot
        }
    }

    let fb = bb.fb
    let head = fb.block(fb.fresh_label("fit_head"))
    let body = fb.block(fb.fresh_label("fit_body"))
    let exit = fb.block(fb.fresh_label("fit_exit"))

    bb.br(head.label())
    bb.move_to(&head)
    let nargs: List(Operand) = list(2, ctx.allocator)
    nargs.push(state_addr)
    let nxt = emit_call(ctx, bb, nsym.unwrap(), &ng, nargs)
    let cond = if ol.is_niche {
        bb.icmp_ne(IrType.Ptr, nxt, Operand.NullPtr)
    } else {
        bb.icmp_ne(IrType.I32, bb.load(IrType.I32, nxt), Operand.IntConst(0))
    }
    bb.br_if(cond, body.label(), exit.label())

    bb.move_to(&body)
    let scope = env.mark()
    if ol.is_niche {
        // The payload pointer IS the value; the loop var is a &T.
        let slot = alloc_slot(bb, IrType.Ptr)
        bb.store(IrType.Ptr, nxt, slot)
        env.bind_slot(f.var_name, slot, IrType.Ptr, ety)
    } else {
        let pa = bb.gep(nxt, Operand.IntConst(ol.payload_offset as i64))
        if is_by_ref(ctx, &ety) {
            let elay = layout_of(tyit(ctx), ety, &ctx.result.nominals, ctx.allocator)
            let slot = bb.stack_slot(elay.size as u64, elay.align as u64)
            bb.memcpy(slot, pa, Operand.IntConst(elay.size as i64))
            env.bind_aggregate(f.var_name, slot, ety)
        } else {
            let ir = ir_of(ctx, ety)
            let v = bb.load(ir, pa)
            let slot = alloc_slot(bb, ir)
            bb.store(ir, v, slot)
            env.bind_slot(f.var_name, slot, ir, ety)
        }
    }
    ctx.loops.push(LoopFrame { latch = head.label(), exit = exit.label(),
        defer_depth = ctx.defers.len })
    let r = lower_block(ctx, bb, env, &f.body)
    let _f = ctx.loops.pop()
    env.release(scope)
    if !r.terminated {
        bb.br(head.label())
    }

    bb.move_to(&exit)
}

fn lower_for_range(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, f: &ForStmt, rng: &RangeExpr) {
    if rng.start.is_none() {
        let _u = unlowerable(ctx)
        return
    }
    if rng.end.is_none() {
        let _u = unlowerable(ctx)
        return
    }
    let start_e = rng.start.unwrap()
    let end_e = rng.end.unwrap()

    let ity = node_ty(ctx, expr_span(start_e))
    let p = prim_kind_of_ty(ctx, ity)
    if is_float(p) {
        let _u = unlowerable(ctx)
        return
    }
    let ir = ty_to_ir(ctx, ity)
    let sg = is_signed_integer(p)

    let start = lower_expr(ctx, bb, env, start_e)
    let stop = lower_expr(ctx, bb, env, end_e)

    let fb = bb.fb
    let head = fb.block(fb.fresh_label("for_head"), ir)
    let body = fb.block(fb.fresh_label("for_body"))
    let latch = fb.block(fb.fresh_label("for_latch"))
    let exit = fb.block(fb.fresh_label("for_exit"))

    bb.br_arg(head.label(), start)

    bb.move_to(&head)
    let iv = head.param(0)
    let cond = range_cond(bb, ir, sg, rng.inclusive, iv, stop)
    bb.br_if(cond, body.label(), exit.label())

    bb.move_to(&body)
    let scope = env.mark()
    // The induction variable is a fresh binding per iteration, so it gets its own slot: assigning
    // it inside the body cannot perturb the loop.
    let iv_slot = alloc_slot(bb, ir)
    bb.store(ir, iv, iv_slot)
    env.bind_slot(f.var_name, iv_slot, ir, ity)
    ctx.loops.push(LoopFrame { latch = latch.label(), exit = exit.label(),
        defer_depth = ctx.defers.len })
    let r = lower_block(ctx, bb, env, &f.body)
    let _fr = ctx.loops.pop()
    env.release(scope)
    if !r.terminated {
        bb.br(latch.label())
    }

    bb.move_to(&latch)
    let next = bb.iadd(ir, iv, Operand.IntConst(1))
    bb.br_arg(head.label(), next)

    bb.move_to(&exit)
}

fn range_cond(bb: &BlockBuilder, ir: IrType, sg: bool, inclusive: bool, iv: Operand,
    stop: Operand) Operand {
    if inclusive {
        if sg {
            return bb.icmp_sle(ir, iv, stop)
        }
        return bb.icmp_ule(ir, iv, stop)
    }
    if sg {
        return bb.icmp_slt(ir, iv, stop)
    }
    return bb.icmp_ult(ir, iv, stop)
}

// Calls (M2)
//
// The checker already picked the callee - overload, UFCS receiver, and default arguments are all
// settled by the time lowering runs, and the winner is recorded on the call node as
// `RtFunction(id)`. So lowering does not re-resolve anything: it maps that id through the symbol
// table and emits the args in order.
//
// A call falls back to the placeholder when the node carries no `RtFunction` (a variant
// constructor, an indirect call, or one of the checker's deliberate fresh-var fallbacks such as
// named arguments), or when the callee's signature was outside the lowerable subset - in that case
// there is no definition in the module to link against. `fn(params) { body }` at its literal site
// (RFC-014). Non-capturing: the value is the synthesized function's address. Capturing: build the
// env struct in a slot from the current values of the captured locals (by value - later mutation of
// the outer local is invisible inside). Either way the body's emission is enqueued for the
// post-walk drain.
fn lower_lambda(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, lam: &LambdaExpr) Operand {
    let info_opt = ctx_lambda(ctx, node_id_of(lam.span))
    if info_opt.is_none() {
        return unlowerable(ctx)
    }
    let info = info_opt.unwrap()
    ctx.pending_lambdas.push(PendingLambda {
        lam = lam.*,
        info = info.*,
        overlay = ctx.overlay,
    })
    if info.captures.len == 0 {
        return Operand.FuncRef(info.symbol.as_view())
    }
    let cid = info.closure_id.unwrap()
    let no_args: List(Ty) = list(0, ctx.allocator)
    let cty = ctx.it.nominal_of(cid, &no_args)
    no_args.deinit()
    let target = resolve_struct(ctx, &cty, &ctx.result.nominals, ctx.allocator)
    if target.is_none() {
        return unlowerable(ctx)
    }
    let st = target.unwrap()
    // Zero-fill so field padding reads deterministically - see `lower_variant_call`.
    let slot = bb.stack_slot(st.layout.size as u64, st.layout.align as u64)
    bb.memset(slot, Operand.IntConst(0), Operand.IntConst(st.layout.size as i64))
    for i in 0..info.captures.len {
        let cap = &info.captures[i]
        let v = read_binding(ctx, bb, env, cap.name, &cap.ty)
        let fp = bb.gep(slot, Operand.IntConst(st.layout.offsets[i] as i64))
        if is_by_ref(ctx, &cap.ty) {
            bb.memcpy(fp, v, Operand.IntConst(layout_of(tyit(ctx), cap.ty, &ctx.result.nominals,
                        ctx.allocator).size as i64))
        } else {
            bb.store(ir_of(ctx, cap.ty), v, fp)
        }
    }
    return slot
}

fn lower_call(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, call: &CallExpr) Operand {
    // A call the checker resolved to an enum variant (`Some(x)`, `Color.Red(x)`) is construction,
    // not a function call - there is no callee symbol, and a member-access callee's receiver names
    // a type, not a value to evaluate.
    let vnum = resolved_variant(ctx, call.span)
    if vnum.is_some() {
        return lower_variant_call(ctx, bb, env, call, vnum.unwrap())
    }

    // A call the checker left on a generic template refuses - every generic call site must have
    // been rewritten to its specialization (M10); the symbol table has no entry for a generic
    // scheme, so the lookups stay null.
    let callable: (String, FnSig)? = null
    let target = ctx_target(ctx, node_id_of(call.span))
    let is_foreign_call = false
    if target.is_some() {
        callable = target_callable(ctx, &target.unwrap())
        is_foreign_call = target.unwrap() match {
            RtFunction(fid) => ctx.syms.is_foreign(fid)
            _ => false
        }
    }
    if callable.is_none() {
        // `Type(T)` instantiation syntax is a reified-type VALUE, not a call (minimal RTTI, M11).
        let cty = node_ty(ctx, call.span)
        if nominal_fqn_is(ctx, &cty, FQN_TYPE) {
            return build_typeinfo_value(ctx, bb, &cty)
        }
        // No resolved symbol: the callee may be a VALUE - a closure or a bare fn pointer (RFC-014).
        return lower_callee_value_call(ctx, bb, env, call)
    }
    const sym = callable.unwrap().0
    const sig = callable.unwrap().1

    // `size_of(T)` / `align_of(T)` fold to layout constants (M11). Their stdlib bodies read a
    // `Type(T)` RTTI value this lowering cannot build yet; the answer is a compile-time constant
    // anyway. Same pattern as the reference's `project_info()` intercept.
    let folded = intercept_rtti_layout(ctx, sym, &sig)
    if folded.is_some() {
        return folded.unwrap()
    }

    let args: List(Operand) = list(call.args.len + 2, ctx.allocator)
    // A UFCS call `recv.f(a)` resolved to a free function takes the receiver as its first argument;
    // the AST still shows it as the callee's member base, so it is prepended here. A member-access
    // callee that resolved to a free function is UFCS by construction - a field holding a function
    // value resolves indirectly and never reaches here (no direct target, so the lookup above
    // bailed). An aggregate argument passes its address (what `lower_expr` yields for one); the
    // callee copies - see `lower_function`. The receiver is ADAPTED to the winner's first-parameter
    // shape (value <-> &T), mirroring the checker's in-set receiver adaptation - pushing the raw
    // value against an adapted pick was a silent scalar miscompile (an i8 handed to a `&u8`
    // parameter).
    call.callee.* match {
        MemberAccess(ma) => {
            if sig.params.len == 0 {
                args.deinit()
                return unlowerable(ctx)
            }
            // A receiver the checker resolved through op_deref hops (`receiver_derefs`) calls each
            // hop; the plain path would pass the wrapper's address at the wrong layout.
            args.push(ctx_receiver_deref(ctx, node_id_of(call.span)) match {
                Some(c) => lower_deref_receiver(ctx, bb, env, ma.receiver, c, &sig.params[0])
                None => lower_receiver(ctx, bb, env, ma.receiver, &sig.params[0])
            })
        }
        // RFC-014: `c(args)` on a value whose type declares `op_call`. The checker resolved it as a
        // UFCS call with the CALLEE as the receiver and recorded the (possibly empty) op_deref
        // chain on the call node - that record is the signal, since the AST still shows a plain
        // callee.
        _ => {
            let hops = ctx_receiver_deref(ctx, node_id_of(call.span))
            if hops.is_some() {
                if sig.params.len == 0 {
                    args.deinit()
                    return unlowerable(ctx)
                }
                let c = hops.unwrap()
                if c.len > 0 {
                    args.push(lower_deref_receiver(ctx, bb, env, call.callee, c, &sig.params[0]))
                } else {
                    args.push(lower_receiver(ctx, bb, env, call.callee, &sig.params[0]))
                }
            }
        }
    }
    // When the AST's argument order is not the call's argument order - names selecting parameters,
    // a variadic tail packed into one array literal - the checker recorded the complete
    // parameter-ordered list on the call node (`materialize_arg_list`); it is emitted verbatim
    // here. A call that needs one and has none refuses: the reorder and the pack are never guessed.
    let al = ctx_arg_list(ctx, node_id_of(call.span))
    if al.is_some() {
        let ordered = al.unwrap()
        for i in 0..ordered.len {
            if args.len >= sig.params.len {
                args.deinit()
                return unlowerable(ctx)
            }
            args.push(lower_adapted(ctx, bb, env, &ordered[i], &sig.params[args.len]))
        }
    } else if call_has_named(call) {
        args.deinit()
        return unlowerable_why(ctx, "named-argument call without a resolved argument list")
    } else {
        for i in 0..call.args.len {
            call.args[i] match {
                // Adapted against the parameter it lands in (past the prepended receiver when the
                // call is UFCS).
                Positional(e) => {
                    if args.len >= sig.params.len {
                        args.deinit()
                        return unlowerable(ctx)
                    }
                    args.push(lower_adapted(ctx, bb, env, e, &sig.params[args.len]))
                }
                Named(_) => {}
            }
        }

        // A call that leaves defaulted parameters to the callee has fewer arguments than the
        // definition has parameters. The checker recorded the omitted params' default expressions
        // on the call node (M11, `materialize_default_args`) - lower them here, in parameter order,
        // after the explicit arguments. A short call with no recorded defaults (a `$T`-typed
        // default, the variadic tail) refuses rather than emit an arity C rejects.
        if args.len < sig.params.len {
            let ds = ctx_default_args(ctx, node_id_of(call.span))
            if ds.is_none() {
                args.deinit()
                return unlowerable_why(ctx, "short call without materialized defaults")
            }
            let defaults = ds.unwrap()
            if args.len + defaults.len != sig.params.len {
                args.deinit()
                return unlowerable(ctx)
            }
            for i in 0..defaults.len {
                args.push(lower_expr(ctx, bb, env, &defaults[i]))
            }
        }
    }
    if args.len != sig.params.len {
        args.deinit()
        return unlowerable(ctx)
    }

    // A coercion on the call's result rewrote the node's type; for aggregates that can change
    // representation - see `repr_compatible`.
    let want = node_ty(ctx, call.span)
    if !repr_compatible(ctx, &sig.ret, &want) {
        args.deinit()
        return unlowerable(ctx)
    }

    return emit_call(ctx, bb, sym, &sig, args, is_foreign_call)
}

// A value whose own type is a fixed array landing in a slice-typed slot (a callee's parameter, a
// struct field): the checker's decay coercion changes representation, so the raw array bytes must
// not be handed over as a `{ptr, len}` view - build the view here (the counterpart of the cast and
// literal decay sites). Everything else passes through `lower_expr` unchanged; the consumer's own
// layout reads then match what the checker approved.
fn lower_adapted(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, e: &Expr, want: &Ty) Operand {
    let src = node_ty(ctx, expr_span(e))
    // `[T; N]` or `&[T; N]` - either way `lower_expr` yields the elements' base address (an
    // aggregate IS its address; a reference's value is the pointee's).
    let a = tn(ctx, src) match {
        NArray(a0) => Some(a0)
        NRef(i) => tn(ctx, i) match {
            NArray(a1) => Some(a1)
            _ => null
        }
        _ => null
    }
    if a.is_none() {
        return lower_expr(ctx, bb, env, e)
    }
    let arr = a.unwrap()
    let de = tn(ctx, want.*) match {
        NNominal(nn) => slice_elem_of(ctx, &nn)
        _ => null
    }
    if de.is_some() and repr_compatible(ctx, &arr.elem, &de.unwrap()) {
        return build_slice_view(ctx, bb, want, lower_expr(ctx, bb, env, e), arr.length)
    }
    return lower_expr(ctx, bb, env, e)
}

// A resolved target's callable symbol and signature: the specialization when the pick was generic
// (M10), the function's own otherwise. Both null for anything else (a variant, a local, a const).
fn target_callable(ctx: &LowerCtx, t: &ResolvedTarget) (String, FnSig)? {
    let sym: String? = null
    let sig: FnSig? = null
    t.* match {
        RtFunction(id) => {
            sym = ctx.syms.lookup_symbol(id)
            sig = ctx.syms.sig_of(id)
        }
        RtSpecialized(sid) => {
            sym = ctx.syms.spec_symbol(sid)
            sig = ctx.syms.spec_sig(sid)
        }
        _ => {}
    }
    if sym.is_none() or sig.is_none() {
        return null
    }
    return Some((sym.unwrap(), sig.unwrap()))
}

// Call a one-pointer-in, pointer-out hop (`op_deref`) on `addr`.
fn call_hop(ctx: &LowerCtx, bb: &BlockBuilder, sym: String, sig: &FnSig, addr: Operand) Operand {
    let args: List(Operand) = list(1, ctx.allocator)
    args.push(addr)
    return emit_call(ctx, bb, sym, sig, args)
}

// A `{ptr, len}` view slot over `ptr_op` with a constant length - the shape both `[T; N]` decay and
// array literals coerced to slices need. `want` must be the Slice (or String) nominal the node is
// typed as.
fn build_slice_view(ctx: &LowerCtx, bb: &BlockBuilder, want: &Ty, ptr_op: Operand,
    len: usize) Operand {
    let st_opt = resolve_struct(ctx, want, &ctx.result.nominals, ctx.allocator)
    if st_opt.is_none() {
        return unlowerable(ctx)
    }
    let st = st_opt.unwrap()
    let pi = field_index(&st.def, "ptr")
    let li = field_index(&st.def, "len")
    if pi < 0 or li < 0 {
        return unlowerable(ctx)
    }
    let slot = bb.stack_slot(st.layout.size as u64, st.layout.align as u64)
    let pp = bb.gep(slot, Operand.IntConst(st.layout.offsets[pi as usize] as i64))
    bb.store(IrType.Ptr, ptr_op, pp)
    let lp = bb.gep(slot, Operand.IntConst(st.layout.offsets[li as usize] as i64))
    bb.store(IrType.I64, Operand.IntConst(len as i64), lp)
    return slot
}

// `[a, b]` / `[v; N]` (M11): the array builds into a stride-addressed slot; the zero-repeat form
// (`[0u8; N]` - the dominant shape) is one memset. A literal whose node the checker's decay
// coercion rewrote to a Slice wraps the fresh array in a `{ptr, len}` view over it.
fn lower_array_lit(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, al: &ArrayLiteralExpr) Operand {
    let want = node_ty(ctx, al.span)
    let arr = tn(ctx, want) match {
        NArray(a) => Some(a)
        _ => null
    }
    let slice_elem = tn(ctx, want) match {
        NNominal(nn) => slice_elem_of(ctx, &nn)
        _ => null
    }

    let count: usize = al.kind match {
        Elements(es) => es.len
        Repeat(_) => {
            // The repeat count only survives checking as an array length (a non-literal count left
            // the node an unconstrained var, which never reaches here); a decay-coerced repeat
            // literal has nowhere to read the count from and refuses.
            arr match {
                Some(a) => a.length
                None => return unlowerable(ctx)
            }
        }
    }
    let elem = arr match {
        Some(a) => a.elem
        None => slice_elem match {
            Some(e) => e
            None => return unlowerable(ctx)
        }
    }
    if !ty_concrete(tyit(ctx), elem) {
        return unlowerable(ctx)
    }
    let el = layout_of(tyit(ctx), elem, &ctx.result.nominals, ctx.allocator)
    let esize = el.size
    let total = if count == 0 { 1 as usize } else { count * esize }
    let slot = bb.stack_slot(total as u64, el.align as u64)

    al.kind match {
        Elements(es) => {
            for i in 0..es.len {
                let v = lower_expr(ctx, bb, env, &es[i])
                let ep = bb.gep(slot, Operand.IntConst((i * esize) as i64))
                if is_by_ref(ctx, &elem) {
                    bb.memcpy(ep, v, Operand.IntConst(esize as i64))
                } else {
                    bb.store(ir_of(ctx, elem), v, ep)
                }
            }
        }
        Repeat(r) => {
            let v = lower_expr(ctx, bb, env, r.value)
            let is_zero = v match {
                IntConst(k) => k == 0
                NullPtr => true
                _ => false
            }
            if is_zero {
                bb.memset(slot, Operand.IntConst(0), Operand.IntConst((count * esize) as i64))
            } else if esize == 1 and !is_by_ref(ctx, &elem) {
                // memset fills bytes with any value, not just zero - the `[fill; N]` byte-buffer
                // shape is one call, no loop.
                bb.memset(slot, v, Operand.IntConst(count as i64))
            } else {
                // One fill loop whatever the count - the C compiler unrolls small ones. The repeat
                // value is evaluated once, before the loop; the induction variable rides the head
                // block's parameter, the same shape `for i in a..b` lowers to.
                let fb = bb.fb
                let head = fb.block(fb.fresh_label("repfill_head"), IrType.I64)
                let fill = fb.block(fb.fresh_label("repfill_body"))
                let exit = fb.block(fb.fresh_label("repfill_exit"))

                bb.br_arg(head.label(), Operand.IntConst(0))

                bb.move_to(&head)
                let iv = head.param(0)
                let cond = bb.icmp_ult(IrType.I64, iv, Operand.IntConst(count as i64))
                bb.br_if(cond, fill.label(), exit.label())

                bb.move_to(&fill)
                let off = bb.imul(IrType.I64, iv, Operand.IntConst(esize as i64))
                let ep = bb.gep(slot, off)
                if is_by_ref(ctx, &elem) {
                    bb.memcpy(ep, v, Operand.IntConst(esize as i64))
                } else {
                    bb.store(ir_of(ctx, elem), v, ep)
                }
                let next = bb.iadd(IrType.I64, iv, Operand.IntConst(1))
                bb.br_arg(head.label(), next)

                bb.move_to(&exit)
            }
        }
    }

    if arr.is_some() {
        return slot
    }
    return build_slice_view(ctx, bb, &want, slot, count)
}

// `(a, b)` (M11): the tuple builds into a slot, element stores at the tuple layout's offsets - the
// same shape struct literals use. The empty tuple is unit and never reaches value lowering.
fn lower_tuple_lit(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, tl: &TupleLiteralExpr) Operand {
    // `()` is unit - no value to build.
    if tl.elements.len == 0 {
        return Operand.IntConst(0)
    }
    let want = node_ty(ctx, tl.span)
    let espan = tn(ctx, want) match {
        NTuple(es) => Some(es)
        _ => null
    }
    if espan.is_none() {
        return unlowerable(ctx)
    }
    let tys: List(Ty) = list(espan.unwrap().len, ctx.allocator)
    defer tys.deinit()
    for i in 0..espan.unwrap().len {
        tys.push(tyit(ctx).child_at(espan.unwrap(), i))
    }
    if tys.len != tl.elements.len {
        return unlowerable(ctx)
    }
    if !ty_concrete(tyit(ctx), want) {
        return unlowerable(ctx)
    }
    let sl = tuple_layout(tyit(ctx), &tys, &ctx.result.nominals, ctx.allocator)
    // Zero-fill so element padding reads deterministically - see `lower_variant_call`.
    let slot = bb.stack_slot(sl.size as u64, sl.align as u64)
    bb.memset(slot, Operand.IntConst(0), Operand.IntConst(sl.size as i64))
    for i in 0..tl.elements.len {
        let v = lower_expr(ctx, bb, env, &tl.elements[i])
        let ep = bb.gep(slot, Operand.IntConst(sl.offsets[i] as i64))
        let ety = tys[i]
        if is_by_ref(ctx, &ety) {
            let esz = layout_of(tyit(ctx), ety, &ctx.result.nominals, ctx.allocator).size
            bb.memcpy(ep, v, Operand.IntConst(esz as i64))
        } else {
            bb.store(ir_of(ctx, ety), v, ep)
        }
    }
    return slot
}

// The element type when `nr` is the well-known Slice; null otherwise.
fn slice_elem_of(ctx: &LowerCtx, nr: &NNominalNode) Ty? {
    let is_slice = ctx.result.nominals.get(nr.id).* match {
        NomStruct(s) => s.fqn == FQN_SLICE
        _ => false
    }
    if !is_slice {
        return null
    }
    if nr.args.len != 1 {
        return null
    }
    return Some(tyit(ctx).child_at(nr.args, 0))
}

// `a..b` in value position: build the checker-typed `Range(T)` struct into a slot - two scalar
// stores at the layout's offsets, like the string view build. This is the shape the stdlib's
// range-slicing `op_index(s, Range(usize))` overloads consume, which is what unlocks `xs[a..b]`
// (the checker records that pick like any indexing). A partial range (`a..`, `..b`) has no value
// shape yet - zero in-tree sites - and refuses; `for` headers never reach here.
fn lower_range_value(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, r: &RangeExpr) Operand {
    // A bare partial range has no bound to default from; only an INDEX position knows the
    // receiver's length (`lower_index_arg`).
    if r.start.is_none() or r.end.is_none() {
        return unlowerable(ctx)
    }
    let sv = lower_expr(ctx, bb, env, r.start.unwrap())
    let ev = lower_expr(ctx, bb, env, r.end.unwrap())
    let ty = node_ty(ctx, r.span)
    return build_range_slot(ctx, bb, &ty, sv, ev)
}

// The `Range(T)` struct built from already-lowered bounds.
fn build_range_slot(ctx: &LowerCtx, bb: &BlockBuilder, ty: &Ty, sv: Operand, ev: Operand) Operand {
    let st_opt = resolve_struct(ctx, ty, &ctx.result.nominals, ctx.allocator)
    if st_opt.is_none() {
        return unlowerable(ctx)
    }
    let st = st_opt.unwrap()
    let si = field_index(&st.def, "start")
    let ei = field_index(&st.def, "end")
    if si < 0 or ei < 0 {
        return unlowerable(ctx)
    }
    // The element type is the instantiation's single argument; the bounds are scalars (an
    // aggregate-element range has no meaning).
    let nr = tn(ctx, ty.*) match {
        NNominal(n) => Some(n)
        _ => null
    }
    if nr.is_none() {
        return unlowerable(ctx)
    }
    let n = nr.unwrap()
    if n.args.len != 1 {
        return unlowerable(ctx)
    }
    let elem = tyit(ctx).child_at(n.args, 0)
    if is_by_ref(ctx, &elem) {
        return unlowerable(ctx)
    }
    let ir = ir_of(ctx, elem)

    let slot = bb.stack_slot(st.layout.size as u64, st.layout.align as u64)
    let sp = bb.gep(slot, Operand.IntConst(st.layout.offsets[si as usize] as i64))
    bb.store(ir, sv, sp)
    let ep = bb.gep(slot, Operand.IntConst(st.layout.offsets[ei as usize] as i64))
    bb.store(ir, ev, ep)
    return slot
}

// A UFCS receiver adapted to the winner's first-parameter shape. The checker commits value <-> &T
// adaptation in-set and REWRITES the receiver node's recorded type to the adapted form, so the node
// table cannot tell the two apart - the decision reads the receiver's MEMORY type (a binding's
// declared type, a field's substituted declaration) instead. Only scalar-&-primitive shapes need
// care: an aggregate's value IS its address, so every aggregate combination coincides and takes the
// plain path.
//   - param `&prim`, memory holds the prim  -> the place's address
//   - param `&prim`, memory holds `&prim`   -> the pointer value
//   - param prim,    memory holds `&prim`   -> load through
// Anything else scalar-adapted (a temporary receiver) refuses - passing raw bytes at the wrong
// indirection was a silent miscompile (an i8 handed to a `&u8` parameter). Receivers that resolved
// through an op_deref chain never reach here - `lower_call` routes them to `lower_deref_receiver`
// via `receiver_derefs`.
fn lower_receiver(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, recv: &Expr, want: &Ty) Operand {
    let want_inner = tn(ctx, want.*) match {
        NRef(i) => Some(i)
        _ => null
    }
    let want_ref_prim = want_inner.is_some() and is_prim(ctx, want_inner.unwrap())

    if want_ref_prim {
        let inner = want_inner.unwrap()
        let mem = receiver_place_mem(ctx, bb, env, recv)
        if mem.is_none() {
            // A temporary receiver (`n.double().add_five()`): spill the value into a fresh slot and
            // pass its address - the same `&temporary` rule call arguments already have.
            let rty = node_ty(ctx, expr_span(recv))
            if !prim_rep_eq(ctx, rty, inner) {
                return unlowerable_why(ctx, "scalar &prim receiver with no place")
            }
            let v = lower_expr(ctx, bb, env, recv)
            let slot = alloc_slot(bb, ir_of(ctx, rty))
            bb.store(ir_of(ctx, rty), v, slot)
            return slot
        }
        let m = mem.unwrap()
        if ref_prim_rep_eq(ctx, m.ty, want.*) {
            // The memory already holds the &prim - its value is the arg.
            return bb.load(IrType.Ptr, m.addr)
        }
        if prim_rep_eq(ctx, m.ty, inner) {
            return m.addr
        }
        return unlowerable_why(ctx, "scalar receiver adaptation mismatch")
    }

    if is_prim(ctx, want.*) {
        let mem = receiver_place_mem(ctx, bb, env, recv)
        if mem.is_some() {
            let m = mem.unwrap()
            let m_inner = tn(ctx, m.ty) match {
                NRef(i) => Some(i)
                _ => null
            }
            if m_inner.is_some() and prim_rep_eq(ctx, m_inner.unwrap(), want.*) {
                // `&prim` memory adapted to a by-value prim: load through.
                let p = bb.load(IrType.Ptr, m.addr)
                return bb.load(ir_of(ctx, want.*), p)
            }
        }
    }

    return lower_expr(ctx, bb, env, recv)
}

// A UFCS receiver that resolved through op_deref hops (checker's `deref_retry`): call each hop on
// the previous pointer - the wrapper's own address first - and hand the last hop's `&inner` to the
// winner. Every hop is `(&Wrapper) &Inner`, scalar ptr in and out. When the winner takes the inner
// value as a scalar prim, load through.
fn lower_deref_receiver(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, recv: &Expr,
    chain: &List(ResolvedTarget), want: &Ty) Operand {
    // An aggregate receiver lowers to its address; that is the first hop's argument. A
    // scalar-classified wrapper local also needs its ADDRESS - take the place when there is one.
    let cur = receiver_place_mem(ctx, bb, env, recv) match {
        Some(m) => m.addr
        None => lower_expr(ctx, bb, env, recv)
    }
    for i in 0..chain.len {
        const c = target_callable(ctx, &chain[i]) match {
            Some(c) => c
            None => return unlowerable_why(ctx, "op_deref hop without a callable symbol")
        }
        cur = call_hop(ctx, bb, c.0, &c.1, cur)
    }
    if is_prim(ctx, want.*) {
        return bb.load(ir_of(ctx, want.*), cur)
    }
    return cur
}

// Same-scalar-representation compares: the checker may commit a pick whose prim differs in NAME but
// not in machine representation (a `&usize` receiver on a `deinit(&u64)` winner - equal
// specificity, zero-cost coercion, declaration order arbitrates). The bytes are the same; the call
// is sound.
fn prim_rep_eq(ctx: &LowerCtx, a: Ty, b: Ty) bool {
    let pa = tn(ctx, a) match {
        NPrim(p) => p
        _ => return false
    }
    let pb = tn(ctx, b) match {
        NPrim(p) => p
        _ => return false
    }
    return prim_ir(pa) == prim_ir(pb)
}

fn ref_prim_rep_eq(ctx: &LowerCtx, a: Ty, b: Ty) bool {
    let ia = tn(ctx, a) match {
        NRef(i) => i
        _ => return false
    }
    let ib = tn(ctx, b) match {
        NRef(i) => i
        _ => return false
    }
    return prim_rep_eq(ctx, ia, ib)
}

fn is_prim(ctx: &LowerCtx, ty: Ty) bool {
    return tn(ctx, ty) match {
        NPrim(_) => true
        _ => false
    }
}

// A receiver's storage: its address and the type of what the memory actually holds. Null when the
// receiver is not a place this lowering can name (a temporary).
type PlaceMem = struct {
    addr: Operand
    ty: Ty
}

fn receiver_place_mem(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, recv: &Expr) PlaceMem? {
    return recv.* match {
        Identifier(id) => {
            let b = env.get(id.name)
            b match {
                Some(slot) => Some(PlaceMem { addr = slot.addr, ty = slot.src })
                None => {
                    let tgt = ctx_target(ctx, node_id_of(id.span))
                    if tgt.is_none() {
                        return null
                    }
                    tgt.unwrap() match {
                        RtConst(fqn) => {
                            let ci = ctx.consts.get(fqn)
                            ci match {
                                Some(c) => Some(PlaceMem { addr = Operand.GlobalRef(c.sym),
                                    ty = c.ty })
                                None => null
                            }
                        }
                        _ => null
                    }
                }
            }
        }
        MemberAccess(ma) => {
            let mf = member_field(ctx, bb, env, &ma)
            mf match {
                Some(f) => Some(PlaceMem { addr = f.addr, ty = f.fty })
                None => null
            }
        }
        // `b.*.m()` - the pointee (through a reference or op_deref) is the receiver's memory.
        Dereference(d) => deref_target(ctx, bb, env, &d) match {
            Some(t) => Some(PlaceMem { addr = t.1, ty = t.0 })
            None => null
        }
        _ => null
    }
}

// A `Type(T)` handle in value position (minimal RTTI, M11): a TypeInfo slot with size, align, and
// kind filled from T's layout; every other field zeroed (name is the empty string - populate when a
// consumer needs it). `ty` is the node's `core.rtti.Type(T)` nominal.
fn build_typeinfo_value(ctx: &LowerCtx, bb: &BlockBuilder, ty: &Ty) Operand {
    let nr = tn(ctx, ty.*) match {
        NNominal(n) => n
        _ => return unlowerable(ctx)
    }
    if nr.args.len != 1 {
        return unlowerable(ctx)
    }
    let t = tyit(ctx).child_at(nr.args, 0)
    if !ty_concrete(tyit(ctx), t) {
        return unlowerable_why(ctx, "Type(T) of a non-concrete T")
    }
    return build_typeinfo(ctx, bb, &t, 0usize)
}

// How deep the TypeInfo tree is materialised. Each level costs a stack slot per member type; a
// recursive type (`JsonValue` holds a `List(JsonValue)`) would otherwise never bottom out. Past the
// cap the nested `type_info` pointers are null - readers see the shape they came for and nothing
// beyond it.
const RTTI_MAX_DEPTH: usize = 3

// Build a `TypeInfo` for `t` in a fresh stack slot and return its address. Every member the record
// declares is populated: the type's name, layout, kind, type parameters and arguments, fields
// (structs), variants (enums), and parameters plus return type (function types). The reference
// emits static tables for this; here the tree is built at the use site, which is what the `Type(T)`
// VALUE model already implies (a TypeInfo is an ordinary aggregate, addressed by pointer).
fn build_typeinfo(ctx: &LowerCtx, bb: &BlockBuilder, t: &Ty, depth: usize) Operand {
    let reg = &ctx.result.nominals
    let ti_ty = well_known_ty(ctx, FQN_TYPE_INFO)
    if ti_ty.is_none() {
        return unlowerable_why(ctx, "core.rtti.TypeInfo is not in scope")
    }
    let ti = ti_ty.unwrap()
    let st_opt = resolve_struct(ctx, &ti, reg, ctx.allocator)
    if st_opt.is_none() {
        return unlowerable(ctx)
    }
    let st = st_opt.unwrap()

    let lay = layout_of(tyit(ctx), t.*, reg, ctx.allocator)
    let slot = bb.stack_slot(st.layout.size as u64, st.layout.align as u64)
    bb.memset(slot, Operand.IntConst(0), Operand.IntConst(st.layout.size as i64))

    store_ti_field(ctx, bb, &st, slot, "name", build_string_value(ctx, bb, rtti_type_name(ctx, t)))
    store_ti_field(ctx, bb, &st, slot, "size", Operand.IntConst(lay.size as i64))
    store_ti_field(ctx, bb, &st, slot, "align", Operand.IntConst(lay.align as i64))
    // `kind` is a payload-less ENUM field, so it is an aggregate by the by-ref rule and
    // `store_ti_field` would memcpy from the constant. Its discriminant is an i32; store that width
    // directly.
    let ki = field_index(&st.def, "kind")
    if ki >= 0 {
        bb.store(IrType.I32, Operand.IntConst(rtti_kind_tag(ctx, t)), bb.gep(slot,
                Operand.IntConst(st.layout.offsets[ki as usize] as i64)))
    }

    build_ti_type_params(ctx, bb, &st, slot, t, depth)
    build_ti_fields(ctx, bb, &st, slot, t, depth)
    build_ti_variants(ctx, bb, &st, slot, t)
    build_ti_function(ctx, bb, &st, slot, t, depth)
    return slot
}

// Store one member: an aggregate (a slice view, a String) copies its bytes in, a scalar stores at
// the FIELD's own declared width.
fn store_ti_field(ctx: &LowerCtx, bb: &BlockBuilder, st: &StructTarget, slot: Operand, name: String,
    value: Operand) {
    let fi = field_index(&st.def, name)
    if fi < 0 {
        return
    }
    let idx = fi as usize
    let fty = field_ty(tyit(ctx), &st.def, idx, &st.args)
    let dst = bb.gep(slot, Operand.IntConst(st.layout.offsets[idx] as i64))
    if is_by_ref(ctx, &fty) {
        let flay = layout_of(tyit(ctx), fty, &ctx.result.nominals, ctx.allocator)
        bb.memcpy(dst, value, Operand.IntConst(flay.size as i64))
    } else {
        bb.store(ir_of(ctx, fty), value, dst)
    }
}

// `type_params` is one (empty) name per declared parameter - the registry keeps parameters as var
// ids, not names, so only the COUNT is truthful here - and `type_args` is one TypeInfo pointer per
// argument of the instantiation.
fn build_ti_type_params(ctx: &LowerCtx, bb: &BlockBuilder, st: &StructTarget, slot: Operand, t: &Ty,
    depth: usize) {
    let reg = &ctx.result.nominals
    let nr = tn(ctx, t.*) match {
        NNominal(n) => Some(n)
        _ => null
    }
    if nr.is_none() {
        let none_ptrs: List(Operand) = list(0, ctx.allocator)
        store_ti_field(ctx, bb, st, slot, "type_args", pack_ptr_slice(ctx, bb, &none_ptrs))
        none_ptrs.deinit()
        return
    }
    let n = nr.unwrap()
    let n_params = reg.get(n.id).* match {
        NomStruct(sd) => sd.type_params.len
        NomEnum(ed) => ed.type_params.len
    }
    if n_params > 0 {
        let str_ty = well_known_ty(ctx, FQN_STRING)
        if str_ty.is_some() {
            let names: List(Operand) = list(n_params, ctx.allocator)
            for i in 0..n_params {
                names.push(build_string_value(ctx, bb, ""))
            }
            store_ti_field(ctx, bb, st, slot, "type_params", pack_slice(ctx, bb, &str_ty.unwrap(),
                    &names))
            names.deinit()
        }
    }
    // `type_args` is declared `&TypeInfo[]` - a REFERENCE to a slice, so the field holds a pointer.
    // It is always written, even for zero arguments: a null pointer there makes `t.type_args.len`
    // read through address 0.
    let ptrs: List(Operand) = list(n.args.len, ctx.allocator)
    if depth < RTTI_MAX_DEPTH {
        for i in 0..n.args.len {
            let arg_ti = tyit(ctx).child_at(n.args, i)
            ptrs.push(build_typeinfo(ctx, bb, &arg_ti, depth + 1))
        }
    }
    store_ti_field(ctx, bb, st, slot, "type_args", pack_ptr_slice(ctx, bb, &ptrs))
    ptrs.deinit()
}

fn build_ti_fields(ctx: &LowerCtx, bb: &BlockBuilder, st: &StructTarget, slot: Operand, t: &Ty,
    depth: usize) {
    let reg = &ctx.result.nominals
    let target = resolve_struct(ctx, t, reg, ctx.allocator)
    if target.is_none() {
        return
    }
    let ts = target.unwrap()
    if ts.def.fields.len == 0 {
        return
    }
    let fi_ty = well_known_ty(ctx, FQN_FIELD_INFO)
    if fi_ty.is_none() {
        return
    }
    let fst = resolve_struct(ctx, &fi_ty.unwrap(), reg, ctx.allocator)
    if fst.is_none() {
        return
    }
    let fs = fst.unwrap()

    let items: List(Operand) = list(ts.def.fields.len, ctx.allocator)
    for i in 0..ts.def.fields.len {
        let rec = bb.stack_slot(fs.layout.size as u64, fs.layout.align as u64)
        bb.memset(rec, Operand.IntConst(0), Operand.IntConst(fs.layout.size as i64))
        store_ti_field(ctx, bb, &fs, rec, "name", build_string_value(ctx, bb,
                ts.def.fields[i].name))
        store_ti_field(ctx, bb, &fs, rec, "offset", Operand.IntConst(ts.layout.offsets[i] as i64))
        if depth < RTTI_MAX_DEPTH {
            let fty = field_ty(tyit(ctx), &ts.def, i, &ts.args)
            store_ti_field(ctx, bb, &fs, rec, "type_info", build_typeinfo(ctx, bb, &fty, depth + 1))
        }
        items.push(rec)
    }
    store_ti_field(ctx, bb, st, slot, "fields", pack_slice(ctx, bb, &fi_ty.unwrap(), &items))
    items.deinit()
}

fn build_ti_variants(ctx: &LowerCtx, bb: &BlockBuilder, st: &StructTarget, slot: Operand, t: &Ty) {
    let reg = &ctx.result.nominals
    let target = resolve_enum(ctx, t, reg)
    if target.is_none() {
        return
    }
    let te = target.unwrap()
    if te.def.variants.len == 0 {
        return
    }
    let vi_ty = well_known_ty(ctx, FQN_VARIANT_INFO)
    if vi_ty.is_none() {
        return
    }
    let vst = resolve_struct(ctx, &vi_ty.unwrap(), reg, ctx.allocator)
    if vst.is_none() {
        return
    }
    let vs = vst.unwrap()

    let items: List(Operand) = list(te.def.variants.len, ctx.allocator)
    for i in 0..te.def.variants.len {
        let rec = bb.stack_slot(vs.layout.size as u64, vs.layout.align as u64)
        bb.memset(rec, Operand.IntConst(0), Operand.IntConst(vs.layout.size as i64))
        store_ti_field(ctx, bb, &vs, rec, "name", build_string_value(ctx, bb,
                te.def.variants[i].name))
        items.push(rec)
    }
    store_ti_field(ctx, bb, st, slot, "variants", pack_slice(ctx, bb, &vi_ty.unwrap(), &items))
    items.deinit()
}

// Function types carry their parameters and return type; every other kind leaves both members at
// their zeroed default (an empty slice and a null pointer), which is what `rtti_params_empty` /
// `rtti_return_type_null` read.
fn build_ti_function(ctx: &LowerCtx, bb: &BlockBuilder, st: &StructTarget, slot: Operand, t: &Ty,
    depth: usize) {
    let ft = tn(ctx, t.*) match {
        NFunc(f) => Some(f)
        _ => null
    }
    if ft.is_none() {
        return
    }
    let f = ft.unwrap()
    if depth >= RTTI_MAX_DEPTH {
        return
    }
    let reg = &ctx.result.nominals

    if f.params.len > 0 {
        let pi_ty = well_known_ty(ctx, FQN_PARAM_INFO)
        if pi_ty.is_some() {
            let pst = resolve_struct(ctx, &pi_ty.unwrap(), reg, ctx.allocator)
            if pst.is_some() {
                let ps = pst.unwrap()
                let items: List(Operand) = list(f.params.len, ctx.allocator)
                for i in 0..f.params.len {
                    let rec = bb.stack_slot(ps.layout.size as u64, ps.layout.align as u64)
                    bb.memset(rec, Operand.IntConst(0), Operand.IntConst(ps.layout.size as i64))
                    // A function TYPE has no parameter names.
                    store_ti_field(ctx, bb, &ps, rec, "name", build_string_value(ctx, bb, ""))
                    let pti = tyit(ctx).child_at(f.params, i)
                    store_ti_field(ctx, bb, &ps, rec, "type_info", build_typeinfo(ctx, bb, &pti,
                            depth + 1))
                    items.push(rec)
                }
                store_ti_field(ctx, bb, st, slot, "params", pack_slice(ctx, bb, &pi_ty.unwrap(),
                        &items))
                items.deinit()
            }
        }
    }
    if f.ret != TY_VOID {
        store_ti_field(ctx, bb, st, slot, "return_type", build_typeinfo(ctx, bb, &f.ret, depth + 1))
    }
}

// Copy `items` (each an aggregate ADDRESS) into one contiguous array and return a `Slice(elem)`
// view over it.
fn pack_slice(ctx: &LowerCtx, bb: &BlockBuilder, elem: &Ty, items: &List(Operand)) Operand {
    let lay = layout_of(tyit(ctx), elem.*, &ctx.result.nominals, ctx.allocator)
    let buf = bb.stack_slot((lay.size * items.len) as u64, lay.align as u64)
    for i in 0..items.len {
        bb.memcpy(bb.gep(buf, Operand.IntConst((lay.size * i) as i64)), items[i],
            Operand.IntConst(lay.size as i64))
    }
    let sty = slice_ty_of(ctx, elem.*)
    if sty.is_none() {
        return unlowerable_why(ctx, "core.slice.Slice is not in scope")
    }
    return build_slice_view(ctx, bb, &sty.unwrap(), buf, items.len)
}

// The `&TypeInfo[]` counterpart: an array of POINTERS, not records.
fn pack_ptr_slice(ctx: &LowerCtx, bb: &BlockBuilder, ptrs: &List(Operand)) Operand {
    let buf = bb.stack_slot((8 * ptrs.len) as u64, 8u64)
    for i in 0..ptrs.len {
        bb.store(IrType.Ptr, ptrs[i], bb.gep(buf, Operand.IntConst((8 * i) as i64)))
    }
    let ti = well_known_ty(ctx, FQN_TYPE_INFO)
    if ti.is_none() {
        return unlowerable(ctx)
    }
    let sty = slice_ty_of(ctx, mk_ref_ty(ctx, ti.unwrap()))
    if sty.is_none() {
        return unlowerable(ctx)
    }
    return build_slice_view(ctx, bb, &sty.unwrap(), buf, ptrs.len)
}

// `String` over an interned literal - the same `{ptr, len}` shape string literals lower to.
fn build_string_value(ctx: &LowerCtx, bb: &BlockBuilder, text: String) Operand {
    let sty = well_known_ty(ctx, FQN_STRING)
    if sty.is_none() {
        return unlowerable(ctx)
    }
    let s = sty.unwrap()
    let interned = intern_string(ctx, text)
    if interned.is_none() {
        return unlowerable(ctx)
    }
    let e = interned.unwrap()
    return build_slice_view(ctx, bb, &s, Operand.GlobalRef(e.name), e.len)
}

fn well_known_ty(ctx: &LowerCtx, fqn: String) Ty? {
    let id = ctx.result.nominals.by_fqn.get(fqn)
    if id.is_none() {
        return null
    }
    let no_args: List(Ty) = list(0, ctx.allocator)
    defer no_args.deinit()
    return Some(ctx.it.nominal_of(id.unwrap(), &no_args))
}

fn slice_ty_of(ctx: &LowerCtx, elem: Ty) Ty? {
    let id = ctx.result.nominals.by_fqn.get(FQN_SLICE)
    if id.is_none() {
        return null
    }
    let args: List(Ty) = list(1, ctx.allocator)
    defer args.deinit()
    args.push(elem)
    return Some(ctx.it.nominal_of(id.unwrap(), &args))
}

fn mk_ref_ty(ctx: &LowerCtx, inner: Ty) Ty {
    return ctx.it.ref_of(inner)
}

// The name `TypeInfo.name` reports: a primitive's spelling, a nominal's SHORT name, and a
// structural rendering for the rest. Leaked with the rest of the lowering's synthesized strings.
fn rtti_type_name(ctx: &LowerCtx, t: &Ty) String {
    return tn(ctx, t.*) match {
        NPrim(p) => prim_name(p)
        NVoid => "void"
        NNever => "never"
        NNominal(nn) => rtti_nominal_name(ctx, nn.id)
        NRef(_) => "reference"
        NArray(_) => "array"
        NFunc(_) => "function"
        NTuple(_) => "tuple"
        _ => ""
    }
}

fn rtti_nominal_name(ctx: &LowerCtx, id: NominalId) String {
    let fqn = ctx.result.nominals.get(id).* match {
        NomStruct(sd) => sd.fqn
        NomEnum(ed) => ed.fqn
    }
    let cut = 0usize
    for i in 0..fqn.len {
        if fqn[i] == '.' {
            cut = i + 1
        }
    }
    return fqn[cut..fqn.len]
}

// TypeKind's declaration indices (Primitive, Array, Struct, Enum, Function - the declared values
// coincide with the indices).
fn rtti_kind_tag(ctx: &LowerCtx, t: &Ty) i64 {
    return tn(ctx, t.*) match {
        NArray(_) => 1
        NFunc(_) => 4
        NNominal(nn) => ctx.result.nominals.get(nn.id).* match {
            NomStruct(_) => 2
            NomEnum(_) => 3
        }
        _ => 0
    }
}

// The constant for a `core.rtti.size_of`/`align_of` specialization call: the instantiated `Type(T)`
// parameter names a concrete T whose layout is known here. Null for every other callee - the call
// emits normally.
fn intercept_rtti_layout(ctx: &LowerCtx, sym: String, sig: &FnSig) Operand? {
    let is_size = starts_with(sym, "core__rtti__size_0of__")
    let is_align = starts_with(sym, "core__rtti__align_0of__")
    if !is_size and !is_align {
        return null
    }
    if sig.params.len != 1 {
        return null
    }
    let nr = tn(ctx, sig.params[0]) match {
        NNominal(n) => n
        _ => return null
    }
    let is_type_nominal = ctx.result.nominals.get(nr.id).* match {
        NomStruct(st) => st.fqn == "core.rtti.Type"
        _ => false
    }
    if !is_type_nominal {
        return null
    }
    if nr.args.len != 1 {
        return null
    }
    let t = tyit(ctx).child_at(nr.args, 0)
    if !ty_concrete(tyit(ctx), t) {
        return null
    }
    let lay = layout_of(tyit(ctx), t, &ctx.result.nominals, ctx.allocator)
    if is_size {
        return Some(Operand.IntConst(lay.size as i64))
    }
    return Some(Operand.IntConst(lay.align as i64))
}

// Emit a direct call to `sym` with declared signature `sig`, handling the three return classes:
// void (and Never), scalar, and aggregate - the last through a caller-allocated buffer passed as a
// trailing sret argument, mirroring `lower_function`'s parameter layout. Takes ownership of `args`.
// The result operand of an aggregate-returning call is the buffer's address.
fn emit_call(ctx: &LowerCtx, bb: &BlockBuilder, sym: String, sig: &FnSig, args: List(Operand),
    foreign: bool = false) Operand {
    if foreign {
        return emit_foreign_call(ctx, bb, sym, sig, args)
    }
    if is_by_ref(ctx, &sig.ret) {
        let lay = layout_of(tyit(ctx), sig.ret, &ctx.result.nominals, ctx.allocator)
        let tmp = bb.stack_slot(lay.size as u64, lay.align as u64)
        args.push(tmp)
        bb.call_void(sym, args)
        return tmp
    }
    let returns_value = !(sig.ret == TY_VOID or sig.ret == TY_NEVER)
    if !returns_value {
        bb.call_void(sym, args)
        return Operand.IntConst(0)
    }
    return bb.call(sym, ir_of(ctx, sig.ret), args)
}

// A call across a C boundary. Aggregates travel BY VALUE here, not by address as they do between
// FLang functions: an aggregate argument is loaded from its slot and passed whole, and an aggregate
// result is stored into a fresh slot so the rest of lowering keeps seeing an address. The sret
// convention is deliberately NOT used - the C definition returns its struct normally, and inventing
// a hidden pointer parameter would not match the function this links against.
fn emit_foreign_call(ctx: &LowerCtx, bb: &BlockBuilder, sym: String, sig: &FnSig,
    args: List(Operand)) Operand {
    let n = if args.len < sig.params.len { args.len } else { sig.params.len }
    for i in 0..n {
        let pa = agg_type_of(ctx, &sig.params[i])
        if pa.is_some() {
            args[i] = bb.load(IrType.Agg(pa.unwrap()), args[i])
        }
    }

    let ra = agg_type_of(ctx, &sig.ret)
    if ra.is_some() {
        let a = ra.unwrap()
        let value = bb.call(sym, IrType.Agg(a), args)
        let slot = bb.stack_slot(a.size as u64, a.align as u64)
        bb.store(IrType.Agg(a), value, slot)
        return slot
    }

    let returns_value = !(sig.ret == TY_VOID or sig.ret == TY_NEVER)
    if !returns_value {
        bb.call_void(sym, args)
        return Operand.IntConst(0)
    }
    return bb.call(sym, ir_of(ctx, sig.ret), args)
}

// A call whose callee is a value rather than a resolved symbol. A closure value dispatches directly
// to its synthesized op_call with the value's address as the leading env argument; a bare fn-typed
// value calls through `CallIndirect`. Anything else is a call the checker left unresolved - refuse.
fn lower_callee_value_call(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, call: &CallExpr) Operand {
    let callee_ty = node_ty(ctx, expr_span(call.callee))

    let nid = tn(ctx, callee_ty) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    if nid.is_some() {
        let cs = ctx.result.get_closure(nid.unwrap())
        if cs.is_none() {
            return unlowerable(ctx)
        }
        let c = cs.unwrap()
        let args: List(Operand) = list(call.args.len + 2, ctx.allocator)
        // The closure struct is an aggregate: lowering it yields its address, which IS the env
        // pointer op_call expects.
        args.push(lower_expr(ctx, bb, env, call.callee))
        for i in 0..call.args.len {
            call.args[i] match {
                Positional(e) => args.push(lower_expr(ctx, bb, env, e))
                Named(_) => {}
            }
        }
        if args.len != c.params.len + 1 {
            args.deinit()
            return unlowerable(ctx)
        }
        let want = node_ty(ctx, call.span)
        if !repr_compatible(ctx, &c.ret, &want) {
            args.deinit()
            return unlowerable(ctx)
        }
        let sig_params: List(Ty) = list(0, ctx.allocator)
        let sig = FnSig { params = sig_params, ret = c.ret }
        return emit_call(ctx, bb, c.symbol.as_view(), &sig, args)
    }

    let ft = tn(ctx, callee_ty) match {
        NFunc(f) => Some(f)
        _ => null
    }
    if ft.is_none() {
        return call.callee.* match {
            Identifier(id) => unlowerable_about(ctx, "callee is not a callable value", id.name)
            MemberAccess(mem) => unlowerable_about(ctx, "callee is not a callable value",
                mem.member)
            _ => unlowerable_why(ctx, "callee is not a callable value")
        }
    }
    let f = ft.unwrap()
    let fn_ptr = lower_expr(ctx, bb, env, call.callee)
    let n_fparams = f.params.len
    let ptys: List(IrType) = list(n_fparams + 1, ctx.allocator)
    for i in 0..n_fparams {
        ptys.push(ir_of(ctx, tyit(ctx).child_at(f.params, i)))
    }
    let args: List(Operand) = list(call.args.len + 1, ctx.allocator)
    for i in 0..call.args.len {
        call.args[i] match {
            Positional(e) => args.push(lower_expr(ctx, bb, env, e))
            Named(_) => {}
        }
    }
    if args.len != n_fparams {
        args.deinit()
        ptys.deinit()
        return unlowerable(ctx)
    }
    let want = node_ty(ctx, call.span)
    if !repr_compatible(ctx, &f.ret, &want) {
        args.deinit()
        ptys.deinit()
        return unlowerable(ctx)
    }
    if is_by_ref(ctx, &f.ret) {
        let lay = layout_of(tyit(ctx), f.ret, &ctx.result.nominals, ctx.allocator)
        let tmp = bb.stack_slot(lay.size as u64, lay.align as u64)
        args.push(tmp)
        ptys.push(IrType.Ptr)
        bb.call_indirect_void(fn_ptr, ptys, args)
        return tmp
    }
    let returns_value = !(f.ret == TY_VOID or f.ret == TY_NEVER)
    if !returns_value {
        bb.call_indirect_void(fn_ptr, ptys, args)
        return Operand.IntConst(0)
    }
    return bb.call_indirect(fn_ptr, ptys, ir_of(ctx, f.ret), args)
}

// Structs and member access (M4, minimal)
//
// FIR is flat - aggregates are opaque byte buffers addressed by pointer. A struct value is
// therefore the pointer to its bytes: a literal allocates a stack slot and stores each field at its
// layout offset, and a member access geps to the field's offset and loads it. Field offsets come
// from `layout.struct_layout` (auto-repr reorders fields, but offsets stay keyed by declaration
// index, so a field's declared position addresses them directly).

// A struct value's registry definition (field names and types) paired with its computed byte layout
// (per-field offsets, total size, alignment) and the instantiation's type arguments (for
// substituting generic field types - the raw definition stores them against the type parameters).
type StructTarget = struct {
    def: StructDef
    layout: StructLayout
    args: List(Ty)
}

// `S { f = v, ... }` - allocate a slot the size of the struct and store each initializer at its
// field offset. The value is the slot pointer. Aggregate fields copy their bytes; scalar fields
// store by value.
fn lower_struct_lit(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, lit: &StructLiteralExpr) Operand {
    let reg = &ctx.result.nominals
    let ty = node_ty(ctx, lit.span)
    let target = resolve_struct(ctx, &ty, reg, ctx.allocator)
    if target.is_none() {
        return unlowerable(ctx)
    }
    let st = target.unwrap()

    let slot = bb.stack_slot(st.layout.size as u64, st.layout.align as u64)
    // Partial initialization zero-fills: `.{ x = 10 }` on a two-field struct leaves `y` at 0, not
    // at whatever the stack held (spec 3.3, reference parity). Cheap enough to do unconditionally -
    // the stores below overwrite whatever they cover.
    bb.memset(slot, Operand.IntConst(0), Operand.IntConst(st.layout.size as i64))
    for &fi in lit.fields {
        let di = field_index(&st.def, fi.name)
        if di < 0 {
            continue
        }
        let didx = di as usize
        let off = st.layout.offsets[didx]
        // Substituted through the instantiation's arguments - the raw definition stores a generic
        // field against the type parameter, and storing by the parameter's placeholder width
        // corrupts the neighbouring fields.
        let fty = field_ty(tyit(ctx), &st.def, didx, &st.args)
        let v = lower_field_init(ctx, bb, env, fi, &fty)
        let fp = bb.gep(slot, Operand.IntConst(off as i64))
        if is_by_ref(ctx, &fty) {
            bb.memcpy(fp, v, Operand.IntConst(layout_of(tyit(ctx), fty, reg,
                        ctx.allocator).size as i64))
        } else {
            bb.store(ir_of(ctx, fty), v, fp)
        }
    }
    return slot
}

// The value of a field initializer: the explicit expression, or - for shorthand `S { x }` - the
// in-scope binding named like the field, read against the field's (substituted) type.
fn lower_field_init(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, fi: &StructFieldInit,
    fty: &Ty) Operand {
    if fi.value.is_some() {
        return lower_adapted(ctx, bb, env, fi.value.unwrap(), fty)
    }
    return read_binding(ctx, bb, env, fi.name, fty)
}

// Place lowering (docs/spec.md 3.4.1, docs/adr/0003)
//
// `lower_expr` yields a VALUE; `lower_place` yields the ADDRESS of a storage location. They are
// deliberately separate entry points: a place context that reaches for `lower_expr` copies the
// aggregate, and every write through the result is silently discarded - the defect ADR 0003
// documents on the C# side, found at four independent sites there. Null means the expression is not
// a place and has no address.
//
// FIR addresses aggregates by pointer, so today `lower_expr` and `lower_place` happen to agree on a
// struct-typed member. They do *not* agree on a scalar member - `lower_expr` loads it - which is
// exactly what assignment (M3), `&`, and element stores need. The split is established now, before
// those land, so the C# archaeology is not repeated here. Match (M5)
//
// Arms are tested in source order, each test in its own block, so a failed test falls through to
// the next arm's test - a linear chain, not a jump table. A switch over a dense tag is a later
// optimisation; correctness first, and the chain is what guards and overlapping patterns need
// anyway.
//
// The scrutinee is evaluated exactly once. `lower_expr` already yields the right thing for both
// cases: a scalar's value, and an aggregate's address (which payload geps and tag loads need).
//
// Every pattern in the match must be lowerable or the whole match falls back to the placeholder. A
// partially-lowered match is worse than none: an unlowerable pattern has no honest test operand,
// and guessing either way silently takes or skips the wrong arm.

fn lower_match(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, m: &MatchExpr) Operand {
    for i in 0..m.arms.len {
        if !pattern_supported(ctx, &m.arms[i].pattern) {
            return unlowerable_why(ctx, "unsupported match pattern")
        }
    }

    let ty = node_ty(ctx, m.span)
    let yields = yields_value(ctx, ty)

    let scrut_ty = node_ty(ctx, expr_span(m.scrutinee))
    let scrut = lower_expr(ctx, bb, env, m.scrutinee)

    let fb = bb.fb
    // `ir_of` only inside the yielding branch: a valueless match's type may be Void or a
    // never-consumed Var, neither of which has an IR scalar to name.
    let join = if yields {
        fb.block(fb.fresh_label("m_join"), ir_of(ctx, ty))
    } else {
        fb.block(fb.fresh_label("m_join"))
    }

    for &arm in m.arms {
        let arm_bb = fb.block(fb.fresh_label("m_arm"))
        let next_bb = fb.block(fb.fresh_label("m_next"))

        let matched = pattern_test(ctx, bb, env, &arm.pattern, scrut, &scrut_ty)
        bb.br_if(matched, arm_bb.label(), next_bb.label())

        bb.move_to(&arm_bb)
        let scope = env.mark()
        bind_pattern(ctx, bb, env, &arm.pattern, scrut, &scrut_ty)

        // A guard runs with the arm's bindings in scope and, when it fails, falls through to the
        // next arm exactly as a failed test does.
        arm.guard match {
            Some(g) => {
                let body_bb = fb.block(fb.fresh_label("m_body"))
                let gv = lower_expr(ctx, bb, env, g)
                bb.br_if(gv, body_bb.label(), next_bb.label())
                bb.move_to(&body_bb)
            }
            None => {}
        }

        let r = lower_arm_body(ctx, bb, env, arm.body)
        env.release(scope)
        join_from(ctx, bb, join.label(), yields, &r)

        bb.move_to(&next_bb)
    }

    // Falling past the last arm means no pattern matched. Exhaustiveness is the checker's job, so
    // this block keeps its default `unreachable`.
    bb.move_to(&join)
    if yields {
        return join.param(0)
    }
    return Operand.IntConst(0)
}

// An arm body is an expression, but a block body may terminate (`return`), and the caller must not
// then append its own branch to the join - the builder's `set_terminator` would overwrite the
// `ret`.
fn lower_arm_body(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, body: &Expr) BlockResult {
    return body.* match {
        Block(b) => lower_block(ctx, bb, env, &b)
        _ => BlockResult { terminated = false, value = Some(lower_expr(ctx, bb, env, body)) }
    }
}

// Whether every part of `pat` can be lowered. Gates the whole match, so an unsupported form
// degrades to a placeholder rather than a wrong branch.
fn pattern_supported(ctx: &LowerCtx, pat: &Pattern) bool {
    return pat.* match {
        Wildcard(_) => true
        Variable(_) => true
        Literal(l) => literal_testable(&l.value)
        Range(_) => true
        EnumVariant(ev) => variant_supported(ctx, &ev)
        // Alternatives must bind the same names; until binding merges across them, only non-binding
        // alternatives lower.
        Or(o) => or_supported(ctx, &o)
        Struct(sp) => struct_pattern_supported(ctx, &sp)
        Tuple(tp) => tuple_pattern_supported(ctx, &tp)
        // The front end lost this pattern's meaning; treating it as irrefutable would take the arm
        // unconditionally.
        Error(_) => false
    }
}

fn struct_pattern_supported(ctx: &LowerCtx, sp: &StructPattern) bool {
    for i in 0..sp.fields.len {
        sp.fields[i].binding match {
            Some(p) => if !pattern_supported(ctx, p) { return false }
            None => {}
        }
    }
    return true
}

fn tuple_pattern_supported(ctx: &LowerCtx, tp: &TuplePattern) bool {
    for i in 0..tp.elements.len {
        if !pattern_supported(ctx, &tp.elements[i]) {
            return false
        }
    }
    return true
}

fn or_supported(ctx: &LowerCtx, o: &OrPattern) bool {
    for i in 0..o.alternatives.len {
        if !pattern_supported(ctx, &o.alternatives[i]) {
            return false
        }
        if pattern_binds(ctx, &o.alternatives[i]) {
            return false
        }
    }
    return true
}

fn variant_supported(ctx: &LowerCtx, ev: &EnumVariantPattern) bool {
    if resolved_variant(ctx, ev.span).is_none() {
        return false
    }
    for i in 0..ev.payloads.len {
        if !pattern_supported(ctx, &ev.payloads[i]) {
            return false
        }
        if !payload_test_safe(&ev.payloads[i]) {
            return false
        }
    }
    return true
}

// Whether `pat` can be TESTED against payload bytes whose tag conjunct may be false. Tests combine
// with `iand`, not short-circuit branches, so every subtest runs even under a wrong tag: loads are
// in-bounds and masked, but a String subpattern is an `op_eq` CALL on whatever bytes sit there -
// refuse rather than call into garbage.
fn payload_test_safe(pat: &Pattern) bool {
    return pat.* match {
        Literal(l) => l.value match {
            String(_) => false
            _ => true
        }
        Or(o) => {
            for i in 0..o.alternatives.len {
                if !payload_test_safe(&o.alternatives[i]) {
                    return false
                }
            }
            true
        }
        EnumVariant(ev) => {
            for i in 0..ev.payloads.len {
                if !payload_test_safe(&ev.payloads[i]) {
                    return false
                }
            }
            true
        }
        _ => true
    }
}

fn pattern_binds(ctx: &LowerCtx, pat: &Pattern) bool {
    return pat.* match {
        // A bare identifier the checker resolved to a payload-less variant (`Red | Green`) is a
        // test, not a binding.
        Variable(v) => resolved_variant(ctx, v.span).is_none()
        EnumVariant(ev) => ev.payloads.len > 0
        Struct(_) => true
        Tuple(_) => true
        _ => false
    }
}

// Only the literal forms with a FIR constant can be compared against. Strings are the exception
// with a value but no constant - comparing one is a call to `String ==`, which operator dispatch
// does not record yet.
fn literal_testable(v: &LiteralValue) bool {
    return v.* match {
        Int(_) => true
        Float(_) => true
        Bool(_) => true
        Char(_) => true
        Byte(_) => true
        Null => true
        // Tests via the checker-recorded op_eq dispatch (M11); when the record is missing,
        // `literal_test` itself refuses.
        String(_) => true
        _ => false
    }
}

// An i8 telling whether `pat` matches `scrut`. Tests are side-effect free, so `Or` and `Range`
// combine them with bitwise ops rather than branching.
fn pattern_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, pat: &Pattern, scrut: Operand,
    scrut_ty: &Ty) Operand {
    return pat.* match {
        Wildcard(_) => Operand.IntConst(1)
        // A bare identifier is a binding (irrefutable) unless the checker resolved it to a
        // payload-less variant - see `check_variable_pattern`.
        Variable(v) => variable_test(ctx, bb, &v, scrut, scrut_ty)
        Literal(l) => literal_test(ctx, bb, &l, scrut, scrut_ty)
        EnumVariant(ev) => variant_test(ctx, bb, env, &ev, scrut, scrut_ty)
        Or(o) => or_test(ctx, bb, env, &o, scrut, scrut_ty)
        Range(r) => range_test(ctx, bb, env, &r, scrut, scrut_ty)
        Struct(sp) => struct_pattern_test(ctx, bb, env, &sp, scrut, scrut_ty)
        Tuple(tp) => tuple_pattern_test(ctx, bb, env, &tp, scrut, scrut_ty)
        _ => unlowerable(ctx)
    }
}

// A struct pattern matches when every named field's sub-pattern does; shorthand and `..` add no
// test. The scrutinee is an aggregate, so each field is addressed off it and read at the field's
// own width.
fn struct_pattern_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, sp: &StructPattern,
    scrut: Operand, scrut_ty: &Ty) Operand {
    let acc = Operand.IntConst(1)
    let have = false
    for i in 0..sp.fields.len {
        let sub = sp.fields[i].binding match {
            Some(p) => Some(p)
            None => null
        }
        if sub.is_none() {
            continue
        }
        let m = struct_pattern_member(ctx, bb, sp.fields[i].name, scrut, scrut_ty)
        if m.is_none() {
            return unlowerable_why(ctx, "struct pattern field not found")
        }
        let f = m.unwrap()
        let t = pattern_test(ctx, bb, env, sub.unwrap(), f.0, &f.1)
        if !have {
            acc = t
        } else {
            acc = bb.iand(IrType.I8, acc, t)
        }
        have = true
    }
    return acc
}

// The value and type of one field of a struct-typed scrutinee: an aggregate field yields its
// address, a scalar its loaded value - the same shape `pattern_test` expects of a scrutinee.
fn struct_pattern_member(ctx: &LowerCtx, bb: &BlockBuilder, name: String, scrut: Operand,
    scrut_ty: &Ty) (Operand, Ty)? {
    let st = resolve_struct(ctx, scrut_ty, &ctx.result.nominals, ctx.allocator)
    if st.is_none() {
        return null
    }
    let t = st.unwrap()
    let di = field_index(&t.def, name)
    if di < 0 {
        return null
    }
    let idx = di as usize
    let fty = field_ty(tyit(ctx), &t.def, idx, &t.args)
    let addr = bb.gep(scrut, Operand.IntConst(t.layout.offsets[idx] as i64))
    if is_by_ref(ctx, &fty) {
        return Some((addr, fty))
    }
    return Some((bb.load(ir_of(ctx, fty), addr), fty))
}

fn tuple_pattern_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, tp: &TuplePattern,
    scrut: Operand, scrut_ty: &Ty) Operand {
    let acc = Operand.IntConst(1)
    let have = false
    for i in 0..tp.elements.len {
        let m = tuple_pattern_member(ctx, bb, i, scrut, scrut_ty)
        if m.is_none() {
            return unlowerable_why(ctx, "tuple pattern over a non-tuple")
        }
        let e = m.unwrap()
        let t = pattern_test(ctx, bb, env, &tp.elements[i], e.0, &e.1)
        if !have {
            acc = t
        } else {
            acc = bb.iand(IrType.I8, acc, t)
        }
        have = true
    }
    return acc
}

fn tuple_pattern_member(ctx: &LowerCtx, bb: &BlockBuilder, i: usize, scrut: Operand,
    scrut_ty: &Ty) (Operand, Ty)? {
    let elems = tn(ctx, peel_ref(ctx, scrut_ty.*)) match {
        NTuple(es) => Some(es)
        _ => null
    }
    if elems.is_none() {
        return null
    }
    let espan = elems.unwrap()
    if i >= espan.len {
        return null
    }
    let es: List(Ty) = list(espan.len, ctx.allocator)
    defer es.deinit()
    for k in 0..espan.len { es.push(tyit(ctx).child_at(espan, k)) }
    let sl = tuple_layout(tyit(ctx), &es, &ctx.result.nominals, ctx.allocator)
    let addr = bb.gep(scrut, Operand.IntConst(sl.offsets[i] as i64))
    let ety = es[i]
    if is_by_ref(ctx, &ety) {
        return Some((addr, ety))
    }
    return Some((bb.load(ir_of(ctx, ety), addr), ety))
}

fn variable_test(ctx: &LowerCtx, bb: &BlockBuilder, v: &VariablePattern, scrut: Operand,
    scrut_ty: &Ty) Operand {
    let idx = resolved_variant(ctx, v.span)
    if idx.is_none() {
        return Operand.IntConst(1)
    }
    return discriminant_test(ctx, bb, idx.unwrap(), scrut, scrut_ty)
}

fn or_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, o: &OrPattern, scrut: Operand,
    scrut_ty: &Ty) Operand {
    let acc = Operand.IntConst(0)
    for i in 0..o.alternatives.len {
        let alt = pattern_test(ctx, bb, env, &o.alternatives[i], scrut, scrut_ty)
        if i == 0 {
            acc = alt
        } else {
            acc = bb.ior(IrType.I8, acc, alt)
        }
    }
    return acc
}

// `lo..hi` - inclusive on the left, exclusive on the right unless the pattern says otherwise. A
// missing bound is unbounded on that side.
fn range_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, r: &RangePattern, scrut: Operand,
    scrut_ty: &Ty) Operand {
    let ir = ty_to_ir(ctx, scrut_ty.*)
    let p = prim_kind_of_ty(ctx, scrut_ty.*)
    let fl = is_float(p)
    let sg = is_signed_integer(p)

    let acc = Operand.IntConst(1)
    let have = false
    r.start match {
        Some(e) => {
            let lo = lower_expr(ctx, bb, env, e)
            acc = bb.ge_op(ir, fl, sg, scrut, lo)
            have = true
        }
        None => {}
    }
    r.end match {
        Some(e) => {
            let hi = lower_expr(ctx, bb, env, e)
            let upper = if r.inclusive { bb.le_op(ir, fl, sg, scrut, hi) } else { bb.lt_op(ir, fl,
                    sg, scrut, hi) }
            if have {
                acc = bb.iand(IrType.I8, acc, upper)
            } else {
                acc = upper
            }
            have = true
        }
        None => {}
    }
    if !have {
        return Operand.IntConst(1)
    }
    return acc
}

fn literal_test(ctx: &LowerCtx, bb: &BlockBuilder, l: &LiteralPattern, scrut: Operand,
    scrut_ty: &Ty) Operand {
    let v = &l.value
    // `null` is a None test: the niche form compares the pointer against null, the tagged form
    // compares the discriminant against None's tag (0 by declaration order) - `discriminant_test`
    // handles both.
    let is_null = v.* match { Null => true, _ => false }
    if is_null {
        if resolve_enum(ctx, scrut_ty, &ctx.result.nominals).is_some() {
            return discriminant_test(ctx, bb, 0u32, scrut, scrut_ty)
        }
        return unlowerable(ctx)
    }

    // A String pattern is the checker-recorded `op_eq(String, String)` call (M11): build the
    // literal's view and dispatch.
    let sl = v.* match {
        String(s) => Some(s)
        _ => null
    }
    if sl.is_some() {
        let rop = ctx_operator(ctx, node_id_of(l.span))
        if rop.is_none() {
            return unlowerable_why(ctx, "string pattern without op_eq pick")
        }
        let op = rop.unwrap()
        let sym = op_symbol(ctx, &op)
        let sig = op_sig(ctx, &op)
        if sym.is_none() or sig.is_none() {
            return unlowerable(ctx)
        }
        let g = sig.unwrap()
        if g.params.len != 2 {
            return unlowerable(ctx)
        }
        if !repr_compatible(ctx, scrut_ty, &g.params[0]) {
            return unlowerable(ctx)
        }
        let s = sl.unwrap()
        let lit = build_string_view(ctx, bb, &g.params[1], &s)
        let args: List(Operand) = list(2, ctx.allocator)
        args.push(scrut)
        args.push(lit)
        return emit_call(ctx, bb, sym.unwrap(), &g, args)
    }

    let lit = lower_literal_value(ctx, v)
    let ir = ty_to_ir(ctx, scrut_ty.*)
    if is_float(prim_kind_of_ty(ctx, scrut_ty.*)) {
        return bb.fcmp_eq(ir, scrut, lit)
    }
    return bb.icmp_eq(ir, scrut, lit)
}

// `Some(x)` / `Color.Red`: compare the scrutinee's discriminant against the variant index the
// checker resolved, ANDed with each refutable payload subpattern's own test (`Reading(0)`,
// `Ok(None)`). Payloads address like `bind_variant_payload` but type by the variant's DECLARED
// payload type (substituted) - the memory's truth; a literal subpattern's node may carry no
// checker-recorded type. Reading the payload region under a wrong tag is in-bounds (the slot is the
// enum's full size) and the tag conjunct masks the result - String subpatterns are the exception (a
// call, not a load) and are refused in `variant_supported`. A pointer-niche optional carries no
// discriminant - `None` is the null pointer and `Some` is anything else, its payload the scrutinee
// itself.
fn variant_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ev: &EnumVariantPattern,
    scrut: Operand, scrut_ty: &Ty) Operand {
    let vnum = resolved_variant(ctx, ev.span)
    if vnum.is_none() {
        return unlowerable(ctx)
    }
    let acc = discriminant_test(ctx, bb, vnum.unwrap(), scrut, scrut_ty)
    if ev.payloads.len == 0 {
        return acc
    }

    if niche_optional(ctx, scrut_ty) {
        let sub0 = &ev.payloads[0]
        let pty0 = node_ty(ctx, pattern_span(sub0))
        let t0 = pattern_test(ctx, bb, env, sub0, scrut, &pty0)
        return bb.iand(IrType.I8, acc, t0)
    }

    let t = resolve_enum(ctx, scrut_ty, &ctx.result.nominals)
    if t.is_none() {
        return unlowerable(ctx)
    }
    let et = t.unwrap()
    let offs = variant_payload_offsets(tyit(ctx), &et.def, vnum.unwrap() as usize, &et.args,
        &ctx.result.nominals, ctx.allocator)
    if offs.len != ev.payloads.len {
        offs.deinit()
        return unlowerable(ctx)
    }
    for j in 0..ev.payloads.len {
        let sub = &ev.payloads[j]
        // Irrefutable subpatterns (wildcards, plain bindings) always pass.
        let refutable = sub.* match {
            Wildcard(_) => false
            Variable(v) => resolved_variant(ctx, v.span).is_some()
            _ => true
        }
        if !refutable {
            continue
        }
        let dty = variant_payload_ty(tyit(ctx), &et.def, vnum.unwrap() as usize, j, &et.args)
        if dty == TY_VOID {
            continue
        }
        let addr = bb.gep(scrut, Operand.IntConst(offs[j] as i64))
        let value = if is_by_ref(ctx, &dty) { addr } else { bb.load(ir_of(ctx, dty), addr) }
        let tj = pattern_test(ctx, bb, env, sub, value, &dty)
        acc = bb.iand(IrType.I8, acc, tj)
    }
    offs.deinit()
    return acc
}

fn discriminant_test(ctx: &LowerCtx, bb: &BlockBuilder, idx: u32, scrut: Operand,
    scrut_ty: &Ty) Operand {
    if niche_optional(ctx, scrut_ty) {
        // The niche form is only ever `Option(&T)`, whose `None` is declared first and so carries
        // index 0 (stdlib/core/option.f). `None` is the null pointer; anything else is `Some`.
        if idx == 0u32 {
            return bb.icmp_eq(IrType.Ptr, scrut, Operand.NullPtr)
        }
        return bb.icmp_ne(IrType.Ptr, scrut, Operand.NullPtr)
    }

    // A tagged enum is addressed by pointer, with the discriminant first.
    let tag = bb.load(IrType.I32, scrut)
    return bb.icmp_eq(IrType.I32, tag, Operand.IntConst(idx as i64))
}

// Bind the variables `pat` introduces. Runs in the arm's block, after its test succeeded, so every
// gep here is known to be in-bounds for the matched variant.
fn bind_pattern(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, pat: &Pattern, scrut: Operand,
    scrut_ty: &Ty) {
    pat.* match {
        Variable(v) => bind_matched(ctx, bb, env, v.name, scrut, scrut_ty)
        EnumVariant(ev) => bind_variant_payload(ctx, bb, env, &ev, scrut, scrut_ty)
        Struct(sp) => bind_struct_pattern(ctx, bb, env, &sp, scrut, scrut_ty)
        Tuple(tp) => bind_tuple_pattern(ctx, bb, env, &tp, scrut, scrut_ty)
        _ => {}
    }
}

// `Point { x, y = inner }` - shorthand binds the field's own name, an explicit sub-pattern binds
// through itself.
fn bind_struct_pattern(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, sp: &StructPattern,
    scrut: Operand, scrut_ty: &Ty) {
    for i in 0..sp.fields.len {
        let m = struct_pattern_member(ctx, bb, sp.fields[i].name, scrut, scrut_ty)
        if m.is_none() {
            continue
        }
        let f = m.unwrap()
        sp.fields[i].binding match {
            Some(p) => bind_pattern(ctx, bb, env, p, f.0, &f.1)
            None => bind_matched(ctx, bb, env, sp.fields[i].name, f.0, &f.1)
        }
    }
}

fn bind_tuple_pattern(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, tp: &TuplePattern,
    scrut: Operand, scrut_ty: &Ty) {
    for i in 0..tp.elements.len {
        let m = tuple_pattern_member(ctx, bb, i, scrut, scrut_ty)
        // Skipping would leave the element's names unbound, and the body would fail far away with
        // "unbound name read". Refuse here, where the reason is still visible.
        if m.is_none() {
            let _u = unlowerable_why(ctx, "tuple pattern element has no readable type")
            return
        }
        let e = m.unwrap()
        bind_pattern(ctx, bb, env, &tp.elements[i], e.0, &e.1)
    }
}

// A pattern variable names the matched value. An aggregate's operand is an address into the
// scrutinee, so the binding copies into its own slot, same as `let` (value semantics); a scalar
// gets a slot like any other local, so the arm body may assign to it.
fn bind_matched(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, name: String, value: Operand,
    ty: &Ty) {
    if is_by_ref(ctx, ty) {
        let lay = layout_of(tyit(ctx), ty.*, &ctx.result.nominals, ctx.allocator)
        let slot = bb.stack_slot(lay.size as u64, lay.align as u64)
        bb.memcpy(slot, value, Operand.IntConst(lay.size as i64))
        env.bind_aggregate(name, slot, ty.*)
        return
    }
    let ir = ir_of(ctx, ty.*)
    let slot = alloc_slot(bb, ir)
    bb.store(ir, value, slot)
    env.bind_slot(name, slot, ir, ty.*)
}

fn bind_variant_payload(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ev: &EnumVariantPattern,
    scrut: Operand, scrut_ty: &Ty) {
    if ev.payloads.len == 0 {
        return
    }

    // A pointer-niche optional stores its payload *as* the scrutinee - there is no separate payload
    // slot to address.
    if niche_optional(ctx, scrut_ty) {
        let sub0 = &ev.payloads[0]
        let pty0 = node_ty(ctx, pattern_span(sub0))
        bind_pattern(ctx, bb, env, sub0, scrut, &pty0)
        return
    }

    // Each payload binds at its per-payload offset (M11 multi-payload).
    let vnum = resolved_variant(ctx, ev.span)
    let t = resolve_enum(ctx, scrut_ty, &ctx.result.nominals)
    if vnum.is_none() or t.is_none() {
        let _u = unlowerable(ctx)
        return
    }
    let et = t.unwrap()
    let offs = variant_payload_offsets(tyit(ctx), &et.def, vnum.unwrap() as usize, &et.args,
        &ctx.result.nominals, ctx.allocator)
    if offs.len != ev.payloads.len {
        offs.deinit()
        let _u = unlowerable(ctx)
        return
    }
    for j in 0..ev.payloads.len {
        let sub = &ev.payloads[j]
        // A unit payload (`Ok(())`) has no bytes to read or bind.
        let dty = variant_payload_ty(tyit(ctx), &et.def, vnum.unwrap() as usize, j, &et.args)
        if dty == TY_VOID {
            continue
        }
        let pty = node_ty(ctx, pattern_span(sub))
        let addr = bb.gep(scrut, Operand.IntConst(offs[j] as i64))
        let value = if is_by_ref(ctx, &pty) { addr } else { bb.load(ir_of(ctx, pty), addr) }
        bind_pattern(ctx, bb, env, sub, value, &pty)
    }
    offs.deinit()
}

// The variant index the checker resolved for the pattern node at `span`.
fn resolved_variant(ctx: &LowerCtx, span: SourceSpan) u32? {
    let target = ctx_target(ctx, node_id_of(span))
    if target.is_none() {
        return null
    }
    return target.unwrap() match {
        RtEnumVariant(_, idx) => Some(idx)
        _ => null
    }
}

// The enum a scrutinee type names, peeling one reference. The args list is a fresh copy of the
// instantiation's child window; lowering-lifetime scratch, like the rest of the pass.
fn resolve_enum(ctx: &LowerCtx, ty: &Ty, reg: &NominalRegistry) EnumTarget? {
    let nr = tn(ctx, peel_ref(ctx, ty.*)) match {
        NNominal(n) => n
        _ => return null
    }
    let args: List(Ty) = list(nr.args.len, ctx.allocator)
    for i in 0..nr.args.len { args.push(tyit(ctx).child_at(nr.args, i)) }
    return reg.get(nr.id).* match {
        NomEnum(e) => Some(EnumTarget { def = e, args = args })
        _ => null
    }
}

type EnumTarget = struct {
    def: EnumDef
    args: List(Ty)
}

fn niche_optional(ctx: &LowerCtx, ty: &Ty) bool {
    let t = resolve_enum(ctx, ty, &ctx.result.nominals)
    if t.is_none() {
        return false
    }
    let et = t.unwrap()
    return enum_layout(tyit(ctx), &et.def, &et.args, &ctx.result.nominals, ctx.allocator).is_niche
}

fn payload_offset(ctx: &LowerCtx, ty: &Ty) usize {
    let t = resolve_enum(ctx, ty, &ctx.result.nominals)
    if t.is_none() {
        return 4 as usize
    }
    let et = t.unwrap()
    return enum_layout(tyit(ctx), &et.def, &et.args, &ctx.result.nominals,
        ctx.allocator).payload_offset
}

// Enum variant construction (M7)
//
// The checker resolved the variant and recorded `RtEnumVariant` on the node - the same seam
// patterns use - so lowering only builds the value. Three node shapes construct: a call (`Some(x)`,
// `Color.Red(x)`), a bare identifier (`None`, an unqualified `Red`), and a qualified member access
// (`Color.Red`). The niche `Option(&T)` is a retype, not a build: `None` is the null pointer and
// `Some(p)`'s value IS its payload pointer. The tagged form builds into a fresh slot - discriminant
// first (the layout `discriminant_test` reads), payload at the layout's offset.

// `Some(x)` / `Color.Red(x)` - construction with a payload.
fn lower_variant_call(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, call: &CallExpr,
    vnum: u32) Operand {
    if call.args.len == 0 {
        return lower_variant_nullary(ctx, bb, call.span, vnum)
    }

    let ty = node_ty(ctx, call.span)
    let t = resolve_enum(ctx, &ty, &ctx.result.nominals)
    if t.is_none() {
        return unlowerable(ctx)
    }
    let et = t.unwrap()
    let el = enum_layout(tyit(ctx), &et.def, &et.args, &ctx.result.nominals, ctx.allocator)

    // Niche `Some(p)`: the payload pointer is the whole value.
    if el.is_niche {
        let payload0 = call.args[0] match {
            Positional(e) => e
            Named(_) => return unlowerable(ctx)
        }
        return lower_expr(ctx, bb, env, payload0)
    }

    // Zero-fill, tag, then each payload at the variant's per-payload offset (M11 multi-payload).
    // The zero-fill gives the tag-to-payload padding and any unused variant space a deterministic
    // value - byte-wise consumers (the generic hash) read the whole slot. Each slot stores by the
    // variant's DECLARED payload type (substituted through the instantiation) - the memory's truth;
    // a coercion that rewrote an argument node's representation refuses - see `repr_compatible`.
    let offs = variant_payload_offsets(tyit(ctx), &et.def, vnum as usize, &et.args,
        &ctx.result.nominals, ctx.allocator)
    if offs.len != call.args.len {
        offs.deinit()
        return unlowerable(ctx)
    }
    let slot = bb.stack_slot(el.size as u64, el.align as u64)
    bb.memset(slot, Operand.IntConst(0), Operand.IntConst(el.size as i64))
    bb.store(IrType.I32, Operand.IntConst(vnum as i64), slot)
    for j in 0..call.args.len {
        // Named arguments never resolve to a variant - the checker leaves those calls unresolved.
        // (The refusal path leaks `offs` - allocator-lifetime scratch, like the rest of lowering.)
        let pj = call.args[j] match {
            Positional(e) => e
            Named(_) => return unlowerable(ctx)
        }
        let pty = variant_payload_ty(tyit(ctx), &et.def, vnum as usize, j, &et.args)
        // A unit payload (`Ok(())`) stores nothing - the tag is the value.
        if pty == TY_VOID {
            continue
        }
        let aty = node_ty(ctx, expr_span(pj))
        if !repr_compatible(ctx, &aty, &pty) {
            offs.deinit()
            return unlowerable(ctx)
        }
        let v = lower_expr(ctx, bb, env, pj)
        let fp = bb.gep(slot, Operand.IntConst(offs[j] as i64))
        if is_by_ref(ctx, &pty) {
            let psize = layout_of(tyit(ctx), pty, &ctx.result.nominals, ctx.allocator).size
            bb.memcpy(fp, v, Operand.IntConst(psize as i64))
        } else {
            bb.store(ir_of(ctx, pty), v, fp)
        }
    }
    offs.deinit()
    return slot
}

// A payload-less variant in value position: `None`, `Red`, `Color.Red`. The tagged form zero-fills
// the whole slot before the tag store so a later whole-value copy never reads uninitialized bytes -
// the same zeroed-buffer form `lower_null` emits.
fn lower_variant_nullary(ctx: &LowerCtx, bb: &BlockBuilder, span: SourceSpan, vnum: u32) Operand {
    let ty = node_ty(ctx, span)
    let t = resolve_enum(ctx, &ty, &ctx.result.nominals)
    if t.is_none() {
        return unlowerable(ctx)
    }

    let et = t.unwrap()
    let el = enum_layout(tyit(ctx), &et.def, &et.args, &ctx.result.nominals, ctx.allocator)

    // The only nullary variant of the niche form is `None` - the null pointer by definition.
    if el.is_niche {
        return Operand.NullPtr
    }

    let slot = bb.stack_slot(el.size as u64, el.align as u64)
    bb.memset(slot, Operand.IntConst(0), Operand.IntConst(el.size as i64))
    if vnum != 0u32 {
        bb.store(IrType.I32, Operand.IntConst(vnum as i64), slot)
    }
    return slot
}

// Casts (M11) - `x as T`.
//
// The conversion matrix over the checker-recorded source and target types. FIR ops mirror what the
// reference's C emission does: trunc / sign-directed extension between integers (the SOURCE's
// signedness picks zext vs sext, C's conversion rule), fp<->int by the non-float side's signedness,
// fp width changes, and ptr<->int. Pointer-shaped to pointer-shaped (refs, fn values, the niche
// Option) is a no-op, as is an aggregate cast between representation-compatible layouts (String <->
// u8[]). A tagged enum casts to and from integers through its I32 discriminant. Everything else
// refuses.
fn lower_cast(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, c: &CastExpr) Operand {
    let src = node_ty(ctx, expr_span(c.operand))
    let dst = node_ty(ctx, c.span)
    let was_blocked = ctx.blocked
    let r = lower_cast_impl(ctx, bb, env, c, src, dst)
    if ctx.blocked and !was_blocked and ctx.blocked_note.is_none() {
        ctx.blocked_note = Some("cast shape")
    }
    return r
}

fn lower_cast_impl(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, c: &CastExpr, src: Ty,
    dst: Ty) Operand {
    let v = lower_expr(ctx, bb, env, c.operand)
    if src == dst {
        return v
    }

    let s_ag = is_by_ref(ctx, &src)
    let d_ag = is_by_ref(ctx, &dst)
    if s_ag and d_ag {
        // A retype between identical layouts; array decay builds the `{ptr, len}` view (`buf as
        // u8[]`); anything else changes representation and refuses.
        if repr_compatible(ctx, &src, &dst) {
            return v
        }
        let arr = tn(ctx, src) match {
            NArray(a) => Some(a)
            _ => null
        }
        if arr.is_some() {
            let a = arr.unwrap()
            let de = tn(ctx, dst) match {
                NNominal(nn) => slice_elem_of(ctx, &nn)
                _ => null
            }
            if de.is_some() {
                if repr_compatible(ctx, &a.elem, &de.unwrap()) {
                    return build_slice_view(ctx, bb, &dst, v, a.length)
                }
            }
        }
        return unlowerable(ctx)
    }
    if s_ag {
        // Tagged enum -> integer: the discriminant is the value.
        if !is_int_prim(ctx, dst) {
            return unlowerable(ctx)
        }
        let t = resolve_enum(ctx, &src, &ctx.result.nominals)
        if t.is_none() {
            return unlowerable(ctx)
        }
        let tag = bb.load(IrType.I32, v)
        return prim_cast(bb, PrimitiveKind.U32, prim_kind_of_ty(ctx, dst), tag)
    }
    if d_ag {
        // Integer -> tagged enum: a zeroed slot with the converted discriminant stored over it
        // (payload variants read as zeroed).
        if !is_int_prim(ctx, src) {
            return unlowerable(ctx)
        }
        let t = resolve_enum(ctx, &dst, &ctx.result.nominals)
        if t.is_none() {
            return unlowerable(ctx)
        }
        let et = t.unwrap()
        let el = enum_layout(tyit(ctx), &et.def, &et.args, &ctx.result.nominals, ctx.allocator)
        if el.is_niche {
            return unlowerable(ctx)
        }
        let tag = prim_cast(bb, prim_kind_of_ty(ctx, src), PrimitiveKind.U32, v)
        let slot = bb.stack_slot(el.size as u64, el.align as u64)
        bb.memset(slot, Operand.IntConst(0), Operand.IntConst(el.size as i64))
        bb.store(IrType.I32, tag, slot)
        return slot
    }

    // Scalar to scalar. Pointer-shaped scalars (refs, fn values, niche optionals) are all FIR
    // `ptr`.
    let s_ptr = ir_of(ctx, src) match { Ptr => true, _ => false }
    let d_ptr = ir_of(ctx, dst) match { Ptr => true, _ => false }
    if s_ptr and d_ptr {
        return v
    }
    if s_ptr {
        if !is_int_prim(ctx, dst) {
            return unlowerable(ctx)
        }
        return bb.ptrtoint(IrType.Ptr, prim_ir(prim_kind_of_ty(ctx, dst)), v)
    }
    if d_ptr {
        if !is_int_prim(ctx, src) {
            return unlowerable(ctx)
        }
        return bb.inttoptr(prim_ir(prim_kind_of_ty(ctx, src)), IrType.Ptr, v)
    }
    let sp = tn(ctx, src) match { NPrim(p) => Some(p), _ => null }
    let dp = tn(ctx, dst) match { NPrim(p) => Some(p), _ => null }
    if sp.is_none() or dp.is_none() {
        return unlowerable(ctx)
    }
    // `x as bool` would need C's `!= 0` semantics, not a truncation; zero in-tree sites - refuse
    // rather than mis-lower.
    let dst_is_bool = dp.unwrap() match { Bool => true, _ => false }
    let src_is_bool = sp.unwrap() match { Bool => true, _ => false }
    if dst_is_bool and !src_is_bool {
        return unlowerable(ctx)
    }
    return prim_cast(bb, sp.unwrap(), dp.unwrap(), v)
}

fn is_int_prim(ctx: &LowerCtx, ty: Ty) bool {
    return tn(ctx, ty) match {
        NPrim(p) => p match {
            F32 => false
            F64 => false
            _ => true
        }
        _ => false
    }
}

// One primitive to another: the FIR convert op picked by float-ness, width, and the C conversion
// rule's signedness direction.
fn prim_cast(bb: &BlockBuilder, s: PrimitiveKind, d: PrimitiveKind, v: Operand) Operand {
    if s == d {
        return v
    }
    let si = prim_ir(s)
    let di = prim_ir(d)
    let sf = is_float(s)
    let df = is_float(d)
    if sf and df {
        if ir_size(di) > ir_size(si) {
            return bb.fpext(si, di, v)
        }
        return bb.fptrunc(si, di, v)
    }
    if sf {
        if is_signed_integer(d) {
            return bb.fptosi(si, di, v)
        }
        return bb.fptoui(si, di, v)
    }
    if df {
        if is_signed_integer(s) {
            return bb.sitofp(si, di, v)
        }
        return bb.uitofp(si, di, v)
    }
    let sw = ir_size(si)
    let dw = ir_size(di)
    if dw < sw {
        return bb.trunc(si, di, v)
    }
    if dw > sw {
        if is_signed_integer(s) {
            return bb.sext(si, di, v)
        }
        return bb.zext(si, di, v)
    }
    // Same width, different kind (sign or char reinterpretation): the bits carry over; typed C use
    // sites apply the meaning.
    return v
}

// Optional operators (M8)

// `a ?? b` - `a` is an Option (the checker enforced it); yield its payload when present, else
// evaluate `b` - and only then, the right side short-circuits like `or`. Two result shapes, set by
// the checker: the unwrap form (`Option(T) ?? T`) yields `T`, the chain form (`Option(T) ??
// Option(T)`) yields the Option itself. The niche form needs no payload addressing: the pointer IS
// the payload, and the chain result is the same pointer either way.
fn lower_coalesce(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, c: &CoalesceExpr) Operand {
    let lty = node_ty(ctx, expr_span(c.lhs))
    let t = resolve_enum(ctx, &lty, &ctx.result.nominals)
    if t.is_none() {
        return unlowerable(ctx)
    }
    let et = t.unwrap()
    let el = enum_layout(tyit(ctx), &et.def, &et.args, &ctx.result.nominals, ctx.allocator)

    let result_ty = node_ty(ctx, c.span)
    let ir = ir_of(ctx, result_ty)
    let chains = result_ty == lty

    let lhs = lower_expr(ctx, bb, env, c.lhs)
    let present = if el.is_niche {
        bb.icmp_ne(IrType.Ptr, lhs, Operand.NullPtr)
    } else {
        let tag = bb.load(IrType.I32, lhs)
        bb.icmp_ne(IrType.I32, tag, Operand.IntConst(0))
    }

    let fb = bb.fb
    let some_bb = fb.block(fb.fresh_label("co_some"))
    let else_bb = fb.block(fb.fresh_label("co_else"))
    let join = fb.block(fb.fresh_label("co_join"), ir)
    bb.br_if(present, some_bb.label(), else_bb.label())

    bb.move_to(&some_bb)
    // The kept value: the option itself for the chain and niche forms, the payload behind the tag
    // otherwise.
    let kept = lhs
    if !chains and !el.is_niche {
        let addr = bb.gep(lhs, Operand.IntConst(el.payload_offset as i64))
        if is_by_ref(ctx, &result_ty) {
            kept = addr
        } else {
            kept = bb.load(ir_of(ctx, result_ty), addr)
        }
    }
    bb.br_arg(join.label(), kept)

    bb.move_to(&else_bb)
    let rhs = lower_expr(ctx, bb, env, c.rhs)
    bb.br_arg(join.label(), rhs)

    bb.move_to(&join)
    return join.param(0)
}

// `a?.b` (RFC-010) - the receiver is `Option(T)` with `T` a struct (checker-enforced, so the
// receiver is always the tagged form - a struct payload is never pointer-shaped). Branch on the
// tag: present projects the payload's field and wraps it in `Some` - unless the field is itself the
// result Option (the checker's flattening), which passes through directly; absent yields `None`. A
// niche RESULT (`Option(&U)`) is the field's pointer value either way, wrapped and flattened alike,
// with `None` the null pointer.
fn lower_null_propagation(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env,
    np: &NullPropagationExpr) Operand {
    let reg = &ctx.result.nominals
    let rty = node_ty(ctx, expr_span(np.receiver))
    let t = resolve_enum(ctx, &rty, reg)
    if t.is_none() {
        return unlowerable_why(ctx, "`?.` receiver shape")
    }
    let et = t.unwrap()
    if et.args.len != 1 {
        return unlowerable_why(ctx, "`?.` receiver shape")
    }
    let el = enum_layout(tyit(ctx), &et.def, &et.args, reg, ctx.allocator)
    if el.is_niche {
        return unlowerable_why(ctx, "`?.` niche receiver")
    }

    // The projected field's offset and type inside the payload struct.
    let inner = et.args[0]
    let target = resolve_struct(ctx, &inner, reg, ctx.allocator)
    if target.is_none() {
        return unlowerable_why(ctx, "`?.` payload shape")
    }
    let st = target.unwrap()
    let di = field_index(&st.def, np.member)
    if di < 0 {
        return unlowerable_why(ctx, "`?.` member unresolved")
    }
    let off = st.layout.offsets[di as usize]
    let fty = field_ty(tyit(ctx), &st.def, di as usize, &st.args)

    let res_ty = node_ty(ctx, np.span)
    let rt = resolve_enum(ctx, &res_ty, reg)
    if rt.is_none() {
        return unlowerable_why(ctx, "`?.` result shape")
    }
    let ret2 = rt.unwrap()
    let rel = enum_layout(tyit(ctx), &ret2.def, &ret2.args, reg, ctx.allocator)
    let flattens = fty == res_ty

    let recv = lower_expr(ctx, bb, env, np.receiver)
    let tag = bb.load(IrType.I32, recv)
    let present = bb.icmp_ne(IrType.I32, tag, Operand.IntConst(0))

    let fb = bb.fb
    let some_bb = fb.block(fb.fresh_label("np_some"))
    let none_bb = fb.block(fb.fresh_label("np_none"))
    let join = fb.block(fb.fresh_label("np_join"), ir_of(ctx, res_ty))
    bb.br_if(present, some_bb.label(), none_bb.label())

    bb.move_to(&some_bb)
    let payload = bb.gep(recv, Operand.IntConst(el.payload_offset as i64))
    let faddr = bb.gep(payload, Operand.IntConst(off as i64))
    let kept = faddr
    if rel.is_niche {
        kept = bb.load(IrType.Ptr, faddr)
    } else if !flattens {
        // Wrap in `Some` - tag 1 by the well-known Option's declaration order (`None` first), the
        // shape `lower_coalesce`'s presence test already relies on.
        let slot = bb.stack_slot(rel.size as u64, rel.align as u64)
        bb.memset(slot, Operand.IntConst(0), Operand.IntConst(rel.size as i64))
        bb.store(IrType.I32, Operand.IntConst(1), slot)
        let pp = bb.gep(slot, Operand.IntConst(rel.payload_offset as i64))
        if is_by_ref(ctx, &fty) {
            let fsize = layout_of(tyit(ctx), fty, reg, ctx.allocator).size
            bb.memcpy(pp, faddr, Operand.IntConst(fsize as i64))
        } else {
            bb.store(ir_of(ctx, fty), bb.load(ir_of(ctx, fty), faddr), pp)
        }
        kept = slot
    }
    bb.br_arg(join.label(), kept)

    bb.move_to(&none_bb)
    let none_v = if rel.is_niche {
        Operand.NullPtr
    } else {
        let nslot = bb.stack_slot(rel.size as u64, rel.align as u64)
        bb.memset(nslot, Operand.IntConst(0), Operand.IntConst(rel.size as i64))
        nslot
    }
    bb.br_arg(join.label(), none_v)

    bb.move_to(&join)
    return join.param(0)
}

// `expr?` (RFC-009) - the checker resolved `op_try`, proved its return is `TryResult(T, R)`, and
// unified `R` with the enclosing function's return. Lowering emits what the reference's desugar
// produces: call `op_try(operand)`, branch on the result's tag, early-return the `Return` payload,
// continue with the `Continue` payload (`Continue` is declared first in core.try, so its tag is 0).
// A generic `op_try` - the stdlib's Option/Result forms - has no monomorphic symbol until
// specialization (M10), so the lookup refuses and the transitive pass takes the caller with it,
// like every other generic call today.
fn lower_try(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, t: &TryExpr) Operand {
    // `?` inside a deferred expression (E2091 in the reference) would re-enter the flush that is
    // emitting it - refuse.
    if ctx.flushing {
        return unlowerable(ctx)
    }
    let op = ctx_operator(ctx, node_id_of(t.span))
    if op.is_none() {
        return unlowerable_why(ctx, "`?` without a recorded op_try")
    }
    let o = op.unwrap()
    let sym = op_symbol(ctx, &o)
    let sig_opt = op_sig(ctx, &o)
    if sym.is_none() {
        return unlowerable_why(ctx, "op_try without symbol")
    }
    if sig_opt.is_none() {
        return unlowerable_why(ctx, "op_try without sig")
    }
    let sig = sig_opt.unwrap()
    if sig.params.len != 1 {
        return unlowerable(ctx)
    }

    // The TryResult instantiation comes from the callee's declared return - the memory's truth for
    // the tag test and payload access. TryResult is never niche, so the tagged layout always
    // applies.
    let tr = resolve_enum(ctx, &sig.ret, &ctx.result.nominals)
    if tr.is_none() {
        return unlowerable(ctx)
    }
    let et = tr.unwrap()
    if et.def.fqn != FQN_TRY_RESULT {
        return unlowerable(ctx)
    }
    if et.args.len != 2 {
        return unlowerable(ctx)
    }
    let el = enum_layout(tyit(ctx), &et.def, &et.args, &ctx.result.nominals, ctx.allocator)

    let cont_ty = et.args[0]
    let ret_ty = et.args[1]
    let want = node_ty(ctx, t.span)
    if !repr_compatible(ctx, &cont_ty, &want) {
        return unlowerable(ctx)
    }
    // An aggregate early return needs the sret buffer; its absence means the checker already
    // reported the return mismatch.
    if is_by_ref(ctx, &ret_ty) and ctx.sret.is_none() {
        return unlowerable(ctx)
    }

    let v = lower_expr(ctx, bb, env, t.operand)
    let args: List(Operand) = list(2, ctx.allocator)
    args.push(v)
    let res = emit_call(ctx, bb, sym.unwrap(), &sig, args)

    let tag = bb.load(IrType.I32, res)
    let is_cont = bb.icmp_eq(IrType.I32, tag, Operand.IntConst(0))
    let fb = bb.fb
    let cont_bb = fb.block(fb.fresh_label("try_cont"))
    let ret_bb = fb.block(fb.fresh_label("try_ret"))
    bb.br_if(is_cont, cont_bb.label(), ret_bb.label())

    // The early return, mirroring `lower_return`'s sret/scalar split - including the defer flush:
    // `?` escapes every open scope, so the value materializes first, then all active defers fire.
    // Both variants' single payloads sit at the shared payload offset.
    bb.move_to(&ret_bb)
    let raddr = bb.gep(res, Operand.IntConst(el.payload_offset as i64))
    if ctx.sret.is_some() {
        bb.memcpy(ctx.sret.unwrap(), raddr, Operand.IntConst(ctx.ret_size as i64))
        emit_defers_down_to(ctx, bb, env, 0)
        bb.ret_void()
    } else {
        let rv = bb.load(ir_of(ctx, ret_ty), raddr)
        emit_defers_down_to(ctx, bb, env, 0)
        bb.ret(rv)
    }

    bb.move_to(&cont_bb)
    let paddr = bb.gep(res, Operand.IntConst(el.payload_offset as i64))
    if is_by_ref(ctx, &cont_ty) {
        return paddr
    }
    return bb.load(ir_of(ctx, cont_ty), paddr)
}

// Assignment and address-of

// `lhs = rhs` - resolve the destination's address, then evaluate the right side and store through
// it. Destination first, matching the reference compiler's order; the two are independent for every
// expression in the subset, but the order is fixed rather than incidental.
//
// A left side with no address is an already-reported checker error (or an expression this milestone
// can't place); the store is dropped rather than written somewhere arbitrary. Assignment is an
// expression that yields no value, so the result is the unit placeholder.
fn lower_assignment(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, a: &AssignmentExpr) Operand {
    // `base[key] = value` resolved to a user `op_set_index` - an operator record on the ASSIGNMENT
    // node (the lhs index node is not a place).
    let setop = ctx_operator(ctx, node_id_of(a.span))
    if setop.is_some() {
        const ix_opt: IndexExpr? = a.lhs.* match {
            Index(ix) => Some(ix)
            _ => null
        }
        ix_opt match {
            Some(ix) => return set_index_operator_call(ctx, bb, env, &ix, a.rhs, &setop.unwrap())
            None => {}
        }
    }
    let dst = lower_place(ctx, bb, env, a.lhs)
    let v = lower_expr(ctx, bb, env, a.rhs)
    if dst.is_none() {
        return unlowerable_why(ctx, "assignment target is not a place")
    }

    let ty = node_ty(ctx, expr_span(a.lhs))
    if is_by_ref(ctx, &ty) {
        // Aggregates are addressed by pointer, so `v` is the source address and the assignment is a
        // byte copy.
        let lay = layout_of(tyit(ctx), ty, &ctx.result.nominals, ctx.allocator)
        bb.memcpy(dst.unwrap(), v, Operand.IntConst(lay.size as i64))
    } else {
        bb.store(ir_of(ctx, ty), v, dst.unwrap())
    }
    return Operand.IntConst(0)
}

// `&place` - the address itself, with nothing to load or copy.
fn lower_address_of(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, a: &AddressOfExpr) Operand {
    let p = lower_place(ctx, bb, env, a.operand)
    if p.is_some() {
        return p.unwrap()
    }
    // A temporary (`&f()`): materialize it and address the slot. An aggregate's value already IS
    // its buffer's address; a scalar spills. Slot lifetime is the whole function - safe for the
    // argument-position uses this shape appears in.
    let ty = node_ty(ctx, expr_span(a.operand))
    let v = lower_expr(ctx, bb, env, a.operand)
    if is_by_ref(ctx, &ty) {
        return v
    }
    let ir = ir_of(ctx, ty)
    let slot = alloc_slot(bb, ir)
    bb.store(ir, v, slot)
    return slot
}

// `p.*` in value position - the pointer is already the address, so reading through it is one load.
// An aggregate pointee stays a pointer. The memory's type is the operand's pointee, so the load
// takes its width from there; a representation change against the node's recorded type (a coercion)
// refuses - see `repr_compatible`.
fn lower_deref(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, d: &DereferenceExpr) Operand {
    let t = deref_target(ctx, bb, env, d) match {
        Some(t) => t
        None => return unlowerable_why(ctx, "op_deref without a callable symbol")
    }
    let src = t.0
    let ty = node_ty(ctx, d.span)
    if !repr_compatible(ctx, &src, &ty) {
        return unlowerable(ctx)
    }
    if is_by_ref(ctx, &src) {
        return t.1
    }
    return bb.load(ir_of(ctx, src), t.1)
}

// What `d.operand.*` names: (the pointee's type, its address). A reference's value IS that address.
// A nominal operand with a recorded `op_deref` calls it on the operand's own address (its place, or
// the temporary's) and takes the returned pointer - the explicit counterpart of
// `lower_deref_receiver`'s hops. Shared by value reads, place contexts (`&b.*`, `b.*.f`,
// assignment), and UFCS receivers so every position agrees. Null when the recorded operator has no
// callable symbol.
fn deref_target(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, d: &DereferenceExpr) (Ty, Operand)? {
    let op = ctx_operator(ctx, node_id_of(d.span))
    if op.is_none() {
        let oty = node_ty(ctx, expr_span(d.operand))
        return Some((peel_ref(ctx, oty), lower_expr(ctx, bb, env, d.operand)))
    }
    let o = op.unwrap()
    let sym = op_symbol(ctx, &o)
    let sg = op_sig(ctx, &o)
    if sym.is_none() or sg.is_none() {
        return null
    }
    let g = sg.unwrap()
    if g.params.len != 1 {
        return null
    }
    let self_addr = lower_place(ctx, bb, env, d.operand) match {
        Some(a) => a
        None => lower_expr(ctx, bb, env, d.operand)
    }
    return Some((peel_ref(ctx, g.ret), call_hop(ctx, bb, sym.unwrap(), &g, self_addr)))
}

fn lower_place(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, expr: &Expr) Operand? {
    return expr.* match {
        Identifier(id) => place_of_identifier(ctx, env, &id)
        MemberAccess(ma) => member_address(ctx, bb, env, &ma)
        // `p.*` - the pointer already is the address (or op_deref's result).
        Dereference(d) => deref_target(ctx, bb, env, &d) match {
            Some(t) => Some(t.1)
            None => null
        }
        Index(ix) => index_address(ctx, bb, env, &ix)
        _ => null
    }
}

// The address of a base in a place context. Place-ness propagates leftward through a path (spec
// 3.4.1), so a base reached by another path operator is addressed rather than copied.
//
// It propagates through *path operators only*. An identifier base yields its value, which is
// already the right thing in both cases: an aggregate local's value IS its address, and a
// reference's value is the pointer to follow. Addressing the identifier instead would hand back its
// slot - one level of indirection too many.
fn lower_base_address(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, base: &Expr) Operand {
    let nested = base.* match {
        MemberAccess(_) => true
        Index(_) => true
        Dereference(_) => true
        _ => false
    }
    if nested {
        let p = lower_place(ctx, bb, env, base)
        if p.is_some() {
            // A reference-typed path step holds a POINTER to the next struct: its place is the
            // pointer's slot, so follow it - `a.vtable.alloc` must gep into the vtable, not into
            // the field that stores its address.
            let bty = node_ty(ctx, expr_span(base))
            let is_ref = tn(ctx, bty) match { NRef(_) => true, _ => false }
            if is_ref {
                return bb.load(IrType.Ptr, p.unwrap())
            }
            return p.unwrap()
        }
    }
    return lower_expr(ctx, bb, env, base)
}

// A local's storage - every local is slotted, so a name always has an address. A module const's
// place is its global (M11): `&global_allocator` and const member paths address the storage
// directly.
fn place_of_identifier(ctx: &LowerCtx, env: &Env, id: &IdentifierExpr) Operand? {
    let b = env.get(id.name)
    if b.is_some() {
        return Some(b.unwrap().addr)
    }
    let tgt = ctx_target(ctx, node_id_of(id.span))
    if tgt.is_some() {
        tgt.unwrap() match {
            RtConst(fqn) => {
                let ci = ctx.consts.get(fqn)
                if ci.is_some() {
                    return Some(Operand.GlobalRef(ci.unwrap().sym))
                }
            }
            _ => {}
        }
    }
    return null
}

// A resolved member access: the field's address and its declared type, substituted through the
// receiver's type arguments.
type MemberField = struct {
    addr: Operand
    fty: Ty
}

// The address of `ma`'s field paired with the field's declared type. Null when the receiver isn't a
// resolvable struct.
fn member_field(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ma: &MemberAccessExpr) MemberField? {
    let reg = &ctx.result.nominals
    let recv_ty = node_ty(ctx, expr_span(ma.receiver))
    // Tuple projection `t.0` (M11): the "field" is an element index into the tuple layout.
    // Reference-peeled like struct receivers are.
    let telems = tn(ctx, recv_ty) match {
        NTuple(es) => Some(es)
        NRef(inner) => tn(ctx, inner) match {
            NTuple(es2) => Some(es2)
            _ => null
        }
        _ => null
    }
    if telems.is_some() {
        let espan = telems.unwrap()
        let idx = digits_index(ma.member)
        if idx.is_none() {
            return null
        }
        let i = idx.unwrap()
        if i >= espan.len {
            return null
        }
        let tys: List(Ty) = list(espan.len, ctx.allocator)
        defer tys.deinit()
        for k in 0..espan.len { tys.push(tyit(ctx).child_at(espan, k)) }
        let sl = tuple_layout(tyit(ctx), &tys, reg, ctx.allocator)
        let base = lower_base_address(ctx, bb, env, ma.receiver)
        return Some(MemberField {
            addr = bb.gep(base, Operand.IntConst(sl.offsets[i] as i64)),
            fty = tys[i],
        })
    }
    // Peel every reference hop for the lookup; each hop past the first is a load through
    // (`(&&Point).x` - the value of a `&&Point` is the address of a `&Point` cell, one load short
    // of the struct).
    let depth: usize = 0
    let peeled = recv_ty
    loop {
        let inner = tn(ctx, peeled) match {
            NRef(i) => Some(i)
            _ => null
        }
        if inner.is_none() {
            break
        }
        peeled = inner.unwrap()
        depth = depth + 1
    }
    // A receiver the checker resolved through `op_deref` hops (`member_deref_retry`): the field
    // lives in the POINTEE, so each hop runs and the last one's result is the struct to gep into.
    let hops = ctx_receiver_deref(ctx, node_id_of(ma.span))
    if hops.is_some() {
        return deref_member_field(ctx, bb, env, ma, hops.unwrap())
    }

    let target = resolve_struct(ctx, &peeled, reg, ctx.allocator)
    if target.is_none() {
        return null
    }
    let st = target.unwrap()
    let di = field_index(&st.def, ma.member)
    if di < 0 {
        return null
    }
    let off = st.layout.offsets[di as usize]
    let fty = field_ty(tyit(ctx), &st.def, di as usize, &st.args)

    let base = lower_base_address(ctx, bb, env, ma.receiver)
    for _k in 1..depth {
        base = bb.load(IrType.Ptr, base)
    }
    return Some(MemberField { addr = bb.gep(base, Operand.IntConst(off as i64)), fty = fty })
}

// The field of an `op_deref`-forwarded member access: call every hop on the receiver's address,
// then gep into the innermost struct. Null when a hop has no callable symbol or the final type is
// not a struct with that field - both refuse the enclosing function rather than read at a guessed
// offset.
fn deref_member_field(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ma: &MemberAccessExpr,
    chain: &List(ResolvedTarget)) MemberField? {
    let cur = receiver_place_mem(ctx, bb, env, ma.receiver) match {
        Some(m) => m.addr
        None => lower_expr(ctx, bb, env, ma.receiver)
    }
    let inner: Ty? = null
    for i in 0..chain.len {
        const c = target_callable(ctx, &chain[i]) match {
            Some(c) => c
            None => return null
        }
        cur = call_hop(ctx, bb, c.0, &c.1, cur)
        inner = tn(ctx, c.1.ret) match {
            NRef(t) => Some(t)
            _ => null
        }
    }
    if inner.is_none() {
        return null
    }
    let it = inner.unwrap()
    let st = resolve_struct(ctx, &it, &ctx.result.nominals, ctx.allocator) match {
        Some(s) => s
        None => return null
    }
    let di = field_index(&st.def, ma.member)
    if di < 0 {
        return null
    }
    let off = st.layout.offsets[di as usize]
    return Some(MemberField {
        addr = bb.gep(cur, Operand.IntConst(off as i64)),
        fty = field_ty(tyit(ctx), &st.def, di as usize, &st.args),
    })
}

// `t.0`'s element index: the member name as plain digits, else null.
fn digits_index(name: String) usize? {
    if name.len == 0 {
        return null
    }
    let n: usize = 0
    for i in 0..name.len {
        const c = name[i]
        if c < '0' or c > '9' {
            return null
        }
        n = n * 10 + ((c as usize) - 48)
    }
    return Some(n)
}

// The address of `ma`'s field: gep to the field offset off the receiver's address. Null when the
// receiver isn't a resolvable struct.
fn member_address(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ma: &MemberAccessExpr) Operand? {
    let f = member_field(ctx, bb, env, ma)
    if f.is_none() {
        return null
    }
    return Some(f.unwrap().addr)
}

// `recv.field` in VALUE position - address the field, then load a scalar. An aggregate member
// yields its address (FIR addresses aggregates by pointer), so nested `a.b.c` chains gep without an
// intermediate copy. The load's width comes from the field's declared type - the memory's truth -
// and a representation change against the node type (a coercion) refuses.
fn lower_member(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ma: &MemberAccessExpr) Operand {
    // `Color.Red` - a qualified payload-less variant is construction, not field access; the
    // receiver names a type, not a value to address.
    let vnum = resolved_variant(ctx, ma.span)
    if vnum.is_some() {
        return lower_variant_nullary(ctx, bb, ma.span, vnum.unwrap())
    }
    // `arr.len` on a fixed array is its compile-time length; `arr.ptr` is the array's address -
    // which its value already is (M11).
    if ma.member == "len" {
        let rt = node_ty(ctx, expr_span(ma.receiver))
        tn(ctx, rt) match {
            NArray(a) => return Operand.IntConst(a.length as i64)
            _ => {}
        }
    }
    if ma.member == "ptr" {
        let rt2 = node_ty(ctx, expr_span(ma.receiver))
        let is_arr = tn(ctx, rt2) match { NArray(_) => true, _ => false }
        if is_arr {
            return lower_expr(ctx, bb, env, ma.receiver)
        }
    }
    let f = member_field(ctx, bb, env, ma)
    if f.is_none() {
        return unlowerable_why(ctx, "member access unresolved")
    }
    let mf = f.unwrap()
    let mty = node_ty(ctx, ma.span)
    if !repr_compatible(ctx, &mf.fty, &mty) {
        return unlowerable_why(ctx, "member repr mismatch")
    }
    if is_by_ref(ctx, &mf.fty) {
        return mf.addr
    }
    return bb.load(ir_of(ctx, mf.fty), mf.addr)
}

// Indexing (M5)
//
// `xs[i]` has three lowerings, picked by what the checker recorded on the index node:
//
//   - ref-form `op_index_ref(&Self, Idx) &T`: call it. The result IS the
//     element's address, so `xs[i]`, `xs[i] = v` and `&xs[i]` all work off
//     the one call.
//   - value-form `op_index(Self, Idx) T`: call it. The result is a
//     computed temporary - it has no address and is not a place.
//   - nothing recorded: built-in indexing over a fixed array or a slice.
//     The address is `base + i * stride`, which is a place.
//
// Only element indexing is lowered. Range slicing over a built-in base (`xs[a..b]`) has to build a
// new `Slice` value with bounds clamped against the base's length; that is unwritten, and a guess
// would emit an unclamped view that reads past the end. It is refused instead. A *user* type's
// range indexing is an ordinary call and needs nothing extra here - though the two in the stdlib
// (`String`, `Slice`) take their receiver by value, so their signatures are outside the lowerable
// subset for now and the call refuses one step later.

fn lower_index(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ix: &IndexExpr) Operand {
    let op = ctx_operator(ctx, node_id_of(ix.span))
    if op.is_some() {
        let o = op.unwrap()
        // A value-form operator is emitted directly: its result is the value, with nothing to load
        // through.
        if !o.is_ref_form {
            return index_operator_call(ctx, bb, env, ix, &o)
        }
        let addr = index_operator_call(ctx, bb, env, ix, &o)
        let ty = node_ty(ctx, ix.span)
        // FIR addresses aggregates by pointer, so an aggregate element is its own address -
        // `xs[i].f` geps on without an intermediate copy.
        if is_by_ref(ctx, &ty) {
            return addr
        }
        return bb.load(ir_of(ctx, ty), addr)
    }

    // Built-in indexing: the memory's type is the base's element type, so the load takes its width
    // from there; a representation change against the node type (a coercion on the element read)
    // refuses.
    let base_ty = node_ty(ctx, expr_span(ix.receiver))
    let elem = builtin_elem_ty(ctx, &base_ty)
    if elem.is_none() {
        return unlowerable(ctx)
    }
    let ety = elem.unwrap()
    let want = node_ty(ctx, ix.span)
    if !repr_compatible(ctx, &ety, &want) {
        return unlowerable(ctx)
    }

    let addr = builtin_element_address(ctx, bb, env, ix)
    if addr.is_none() {
        return unlowerable(ctx)
    }
    if is_by_ref(ctx, &ety) {
        return addr.unwrap()
    }
    return bb.load(ir_of(ctx, ety), addr.unwrap())
}

// The element's address, when it has one. Null for a value-form operator (a computed temporary) and
// for every form still refused.
fn index_address(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ix: &IndexExpr) Operand? {
    let op = ctx_operator(ctx, node_id_of(ix.span))
    if op.is_some() {
        let o = op.unwrap()
        if !o.is_ref_form {
            return null
        }
        return Some(index_operator_call(ctx, bb, env, ix, &o))
    }
    return builtin_element_address(ctx, bb, env, ix)
}

// The checker already picked the overload, so an indexing operator is an ordinary two-argument call
// through `emit_call` (which handles an aggregate result's sret buffer). The receiver is passed the
// way the chosen shape needs it: a ref-form takes the address, a value form takes what `lower_expr`
// yields - which for an aggregate IS its address, matching how `lower_call` passes aggregate
// arguments.
fn index_operator_call(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ix: &IndexExpr,
    o: &ResolvedOperator) Operand {
    let sym = op_symbol(ctx, o)
    let sig_opt = op_sig(ctx, o)
    if sym.is_none() {
        return unlowerable_why(ctx, "index operator without symbol")
    }
    if sig_opt.is_none() {
        return unlowerable_why(ctx, "index operator without sig")
    }
    let sig = sig_opt.unwrap()
    if sig.params.len != 2 {
        return unlowerable(ctx)
    }
    if !o.is_ref_form {
        // A coercion on the index's result rewrote the node's type; for aggregates that can change
        // representation.
        let want = node_ty(ctx, ix.span)
        if !repr_compatible(ctx, &sig.ret, &want) {
            return unlowerable(ctx)
        }
    }
    let recv = if o.is_ref_form {
        lower_base_address(ctx, bb, env, ix.receiver)
    } else {
        // A value-form receiver adapts like any argument - an array base decays into the slice view
        // the winner's param expects.
        lower_adapted(ctx, bb, env, ix.receiver, &sig.params[0])
    }
    let idx = lower_index_arg(ctx, bb, env, ix, recv)
    let args: List(Operand) = list(3, ctx.allocator)
    args.push(recv)
    args.push(idx)
    return emit_call(ctx, bb, sym.unwrap(), &sig, args)
}

// `base[key] = value` through `op_set_index(&Self, K, V)` (or value-self): an ordinary
// three-argument call; the assignment yields no value.
fn set_index_operator_call(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ix: &IndexExpr, rhs: &Expr,
    o: &ResolvedOperator) Operand {
    let sym = op_symbol(ctx, o)
    let sig_opt = op_sig(ctx, o)
    if sym.is_none() {
        return unlowerable_why(ctx, "set-index operator without symbol")
    }
    if sig_opt.is_none() {
        return unlowerable_why(ctx, "set-index operator without sig")
    }
    let sig = sig_opt.unwrap()
    if sig.params.len != 3 {
        return unlowerable(ctx)
    }
    const self_is_ref = tn(ctx, sig.params[0]) match { NRef(_) => true, _ => false }
    let recv = if self_is_ref {
        lower_base_address(ctx, bb, env, ix.receiver)
    } else {
        lower_adapted(ctx, bb, env, ix.receiver, &sig.params[0])
    }
    let args: List(Operand) = list(3, ctx.allocator)
    args.push(recv)
    args.push(lower_adapted(ctx, bb, env, ix.index, &sig.params[1]))
    args.push(lower_adapted(ctx, bb, env, rhs, &sig.params[2]))
    let _r = emit_call(ctx, bb, sym.unwrap(), &sig, args)
    return Operand.IntConst(0)
}

// The index argument of an operator call. A PARTIAL range literal (`a..`, `..b`, `..`) completes
// against the receiver - the only context that knows its length: start defaults to 0, end to the
// receiver's length (a slice/String `len` field, an array's constant).
fn lower_index_arg(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ix: &IndexExpr,
    recv: Operand) Operand {
    return ix.index.* match {
        Range(r) => lower_partial_range_arg(ctx, bb, env, ix, &r, recv)
        _ => lower_expr(ctx, bb, env, ix.index)
    }
}

fn lower_partial_range_arg(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ix: &IndexExpr,
    r: &RangeExpr, recv: Operand) Operand {
    let has_start = r.start.is_some()
    let has_end = r.end.is_some()
    if has_start and has_end {
        return lower_expr(ctx, bb, env, ix.index)
    }

    let sv = Operand.IntConst(0)
    if has_start {
        let se = r.start.unwrap()
        sv = lower_expr(ctx, bb, env, se)
    }
    let ev = Operand.IntConst(0)
    if has_end {
        let ee = r.end.unwrap()
        ev = lower_expr(ctx, bb, env, ee)
    } else {
        let base_ty = node_ty(ctx, expr_span(ix.receiver))
        let ln = receiver_len(ctx, bb, &base_ty, recv)
        if ln.is_none() {
            return unlowerable(ctx)
        }
        ev = ln.unwrap()
    }
    let rty = node_ty(ctx, r.span)
    return build_range_slot(ctx, bb, &rty, sv, ev)
}

// The length of an indexable receiver value: an array's is a constant; a slice-shaped nominal
// (Slice, String) loads its `len` field through the receiver's address.
fn receiver_len(ctx: &LowerCtx, bb: &BlockBuilder, base_ty: &Ty, recv: Operand) Operand? {
    tn(ctx, base_ty.*) match {
        NArray(a) => return Some(Operand.IntConst(a.length as i64))
        _ => {}
    }
    let st_opt = resolve_struct(ctx, base_ty, &ctx.result.nominals, ctx.allocator)
    if st_opt.is_none() {
        return null
    }
    let st = st_opt.unwrap()
    let li = field_index(&st.def, "len")
    if li < 0 {
        return null
    }
    let lp = bb.gep(recv, Operand.IntConst(st.layout.offsets[li as usize] as i64))
    return Some(bb.load(IrType.I64, lp))
}

// `base + i * sizeof(elem)` for a fixed array or a slice.
fn builtin_element_address(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ix: &IndexExpr) Operand? {
    let base_ty = node_ty(ctx, expr_span(ix.receiver))
    let elem = builtin_elem_ty(ctx, &base_ty)
    if elem.is_none() {
        return null
    }

    // See the header: slicing a built-in base is refused rather than emitted unclamped. Both the
    // syntactic form and a `Range`-typed index reach here.
    if is_range_index(ctx, ix) {
        return null
    }

    let base = builtin_base_pointer(ctx, bb, env, ix.receiver, &base_ty)
    if base.is_none() {
        return null
    }

    let stride = layout_of(tyit(ctx), elem.unwrap(), &ctx.result.nominals, ctx.allocator).size
    let i = lower_expr(ctx, bb, env, ix.index)
    let off = bb.imul(IrType.I64, i, Operand.IntConst(stride as i64))
    return Some(bb.gep(base.unwrap(), off))
}

// The address the elements start at. A fixed array's own address is it; a slice is a `{ptr, len}`
// view, so the pointer is loaded out of its field.
fn builtin_base_pointer(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, recv: &Expr,
    base_ty: &Ty) Operand? {
    let addr = lower_base_address(ctx, bb, env, recv)
    let is_array = tn(ctx, peel_ref(ctx, base_ty.*)) match { NArray(_) => true, _ => false }
    if is_array {
        return Some(addr)
    }

    // Field offsets come from the layout rather than being assumed zero: `auto` repr is free to
    // reorder a struct'''s fields.
    let st = resolve_struct(ctx, base_ty, &ctx.result.nominals, ctx.allocator)
    if st.is_none() {
        return null
    }
    let s = st.unwrap()
    let fi = field_index(&s.def, "ptr")
    if fi < 0 {
        return null
    }
    let fp = bb.gep(addr, Operand.IntConst(s.layout.offsets[fi as usize] as i64))
    return Some(bb.load(IrType.Ptr, fp))
}

// The element type of a built-in indexable base - a fixed array, or the well-known `Slice`. Null
// for everything else, which means the checker either resolved an operator or reported the type as
// non-indexable.
fn builtin_elem_ty(ctx: &LowerCtx, ty: &Ty) Ty? {
    return tn(ctx, peel_ref(ctx, ty.*)) match {
        NArray(a) => Some(a.elem)
        NNominal(n) => slice_element_ty(ctx, &n)
        _ => null
    }
}

fn slice_element_ty(ctx: &LowerCtx, n: &NNominalNode) Ty? {
    let id = ctx.result.nominals.by_fqn.get(FQN_SLICE)
    if id.is_none() {
        return null
    }
    if id.unwrap() != n.id {
        return null
    }
    if n.args.len != 1 {
        return null
    }
    return Some(tyit(ctx).child_at(n.args, 0))
}

// True when the index selects a sub-range rather than one element. Both the literal `a..b` form and
// an index of `Range` type count.
fn is_range_index(ctx: &LowerCtx, ix: &IndexExpr) bool {
    let syntactic = ix.index.* match { Range(_) => true, _ => false }
    if syntactic {
        return true
    }
    let n = tn(ctx, node_ty(ctx, expr_span(ix.index))) match {
        NNominal(nn) => nn
        _ => return false
    }
    let id = ctx.result.nominals.by_fqn.get(FQN_RANGE)
    if id.is_none() {
        return false
    }
    return id.unwrap() == n.id
}

// One reference peeled off. A handle copy either way.
fn peel_ref(ctx: &LowerCtx, ty: Ty) Ty {
    return tn(ctx, ty) match {
        NRef(inner) => inner
        _ => ty
    }
}

// Resolve a value's static type to the struct it names, peeling one reference. Null for enums,
// scalars, and unresolved types - the caller emits its placeholder rather than crash.
fn resolve_struct(ctx: &LowerCtx, ty: &Ty, reg: &NominalRegistry,
    allocator: &Allocator?) StructTarget? {
    let nr = tn(ctx, peel_ref(ctx, ty.*)) match {
        NNominal(n) => n
        _ => return null
    }
    let args: List(Ty) = list(nr.args.len, allocator)
    for i in 0..nr.args.len { args.push(tyit(ctx).child_at(nr.args, i)) }
    return reg.get(nr.id).* match {
        NomStruct(s) => {
            // `Type(T)` values ARE TypeInfo (minimal RTTI, M11): field access and layout go through
            // TypeInfo's definition.
            if s.fqn == FQN_TYPE {
                let ti = reg.by_fqn.get(FQN_TYPE_INFO)
                if ti.is_some() {
                    reg.get(ti.unwrap()).* match {
                        NomStruct(ts) => {
                            args.clear()
                            return Some(StructTarget { def = ts, layout = struct_layout(tyit(ctx),
                                    &ts, &args, reg, allocator), args = args })
                        }
                        _ => {}
                    }
                }
            }
            Some(StructTarget { def = s, layout = struct_layout(tyit(ctx), &s, &args, reg,
                    allocator), args = args })
        }
        _ => null
    }
}

// Declaration index of a named field, or -1 when absent (an already-reported checker error - the
// caller emits a placeholder rather than index past the list).
fn field_index(def: &StructDef, name: String) i64 {
    for i in 0..def.fields.len {
        if def.fields[i].name == name {
            return i as i64
        }
    }
    return -1
}

// Whether a value of `ty` is an in-memory aggregate: addressed by pointer, moved by byte copy,
// passed across calls by address. The pointer-niche `Option(&T)` is not - its value IS the payload
// pointer, held, stored, and passed like any scalar.
fn is_by_ref(ctx: &LowerCtx, ty: &Ty) bool {
    if !is_aggregate(tyit(ctx), ty.*) {
        return false
    }
    return !niche_optional(ctx, ty)
}

// FIR type of a value of `ty`. Aggregates - including the niche optional, whose value is a pointer
// - are `ptr`; scalars map through `ty_to_ir`.
fn ir_of(ctx: &LowerCtx, ty: Ty) IrType {
    if is_aggregate(tyit(ctx), ty) {
        return IrType.Ptr
    }
    return ty_to_ir(ctx, ty)
}

// The by-value C type for an aggregate crossing a FOREIGN boundary, or null when `ty` is not one.
// Native calls never use this - they pass an aggregate's address and return through an sret slot.
// `agg_abi_safe` is the single authority on whether an aggregate may cross, so the call site and
// the emitted definition can never disagree about it.
fn agg_type_of(ctx: &LowerCtx, ty: &Ty) AggType? {
    if !is_aggregate(tyit(ctx), ty.*) {
        return null
    }
    // A pointer-niche `Option(&T)` is an aggregate by shape but a bare pointer by representation -
    // it crosses as `ptr`, not as a struct.
    if niche_optional(ctx, ty) {
        return null
    }
    if !agg_abi_safe(tyit(ctx), ty.*, &ctx.result.nominals) {
        return null
    }
    let fqn = tn(ctx, ty.*) match {
        NNominal(n) => ctx.result.nominals.get(n.id).* match {
            NomStruct(sd) => sd.fqn
            _ => return null
        }
        _ => return null
    }
    let lay = layout_of(tyit(ctx), ty.*, &ctx.result.nominals, ctx.allocator)
    return Some(AggType {
        name = agg_c_name(ctx, fqn),
        size = lay.size,
        align = lay.align,
    })
}

// The struct's members as the backend should write them. Pure - registering them on the module is
// `register_agg`'s job - so validation can call it.
fn agg_fields_of(ctx: &LowerCtx, ty: &Ty) List(AggField)? {
    let sd = tn(ctx, ty.*) match {
        NNominal(n) => ctx.result.nominals.get(n.id).* match {
            NomStruct(d) => d
            _ => return null
        }
        _ => return null
    }
    let fields: List(AggField) = list(sd.fields.len, ctx.allocator)
    for i in 0..sd.fields.len {
        const f = agg_field_of(ctx, &sd.fields[i].ty)
        if f.is_none() {
            fields.deinit()
            return null
        }
        fields.push(f.unwrap())
    }
    return Some(fields)
}

// One struct member. An array keeps its element type and length; a nested aggregate is referenced
// by name; everything else is its FIR scalar.
fn agg_field_of(ctx: &LowerCtx, ty: &Ty) AggField? {
    let elem: Ty = tn(ctx, ty.*) match {
        NArray(a) => a.elem
        _ => ty.*
    }
    let count: usize = tn(ctx, ty.*) match {
        NArray(a) => a.length
        _ => 1
    }
    if is_aggregate(tyit(ctx), elem) and !niche_optional(ctx, &elem) {
        const nested = agg_type_of(ctx, &elem)
        if nested.is_none() {
            return null
        }
        return Some(AggField { ty = IrType.Agg(nested.unwrap()), count = count })
    }
    return Some(AggField { ty = ir_of(ctx, elem), count = count })
}

// Register `ty`'s C definition on the module, and every nested aggregate it contains FIRST - so
// emitting `m.aggs` in order never names a struct that is not defined yet.
fn register_agg(m: &IrModule, ctx: &LowerCtx, ty: &Ty) AggType? {
    const h = agg_type_of(ctx, ty)
    if h.is_none() {
        return null
    }
    let sd = tn(ctx, ty.*) match {
        NNominal(n) => ctx.result.nominals.get(n.id).* match {
            NomStruct(d) => d
            _ => return null
        }
        _ => return null
    }

    // One walk: build each member and register the nested aggregates as we meet them. `agg_type_of`
    // already proved every member spellable.
    let fields: List(AggField) = list(sd.fields.len, ctx.allocator)
    for i in 0..sd.fields.len {
        const f = agg_field_of(ctx, &sd.fields[i].ty)
        if f.is_none() {
            fields.deinit()
            return null
        }
        const elem: Ty = tn(ctx, sd.fields[i].ty) match {
            NArray(a) => a.elem
            _ => sd.fields[i].ty
        }
        if is_aggregate(tyit(ctx), elem) and !niche_optional(ctx, &elem) {
            let _n = register_agg(m, ctx, &elem)
        }
        fields.push(f.unwrap())
    }

    const a = h.unwrap()
    m.add_agg(AggDef { name = a.name, size = a.size, align = a.align, fields = fields })
    return h
}

// A nominal's FQN as a C identifier: `std.simd.Vec128` -> `std_simd_Vec128`, which is also the name
// the companion C writes (see `stdlib/std/simd.c`).
fn agg_c_name(ctx: &LowerCtx, fqn: String) String {
    let sb = string_builder(fqn.len, ctx.allocator)
    for i in 0..fqn.len {
        // `.` -> `_` keeps the common case spelling the companion C already uses (`std.simd.Vec128`
        // -> `std_simd_Vec128`, see stdlib/std/simd.c). `_` -> `_0` is what makes that INJECTIVE:
        // without it `a.b` and `a_b` both produce `a_b`, and `add_agg` dedupes by name, so the
        // second struct would silently reuse the first one's definition. Anything else is not a C
        // identifier byte at all - a module path carries the project name, which no rule constrains
        // - so it is escaped by value. Appending the byte itself emitted `_x-`, still invalid C; a
        // literal `_` is already `_0`, so `_x` is unambiguous.
        if fqn[i] == '.' {
            sb.append("_")
        } else {
            if fqn[i] == '_' {
                sb.append("_0")
            } else {
                if is_c_ident_byte(fqn[i]) {
                    // The one-byte SLICE, not `fqn[i]`: indexing yields a `u8`, which binds the
                    // integer overload and would spell the byte's decimal value into the
                    // identifier.
                    sb.append(fqn[i..(i + 1)])
                } else {
                    sb.append("_x")
                    append_hex_byte(&sb, fqn[i])
                }
            }
        }
    }
    return park_sym(ctx, sb.to_string())
}

// Whether a value produced with representation `src` can flow into a context typed `dst` unchanged.
// The checker's coercions rewrite a node's recorded type in place - lowering never sees the
// original - so each site that knows a value's true source type (a binding's declaration, a field's
// definition, a callee's declared return) checks it here before handing the bytes over.
//
//   - Scalar to scalar is always fine: FIR lands in typed C, where the
//     store or call target's declared type performs the conversion the
//     checker approved (integer widening, char to u8).
//   - Aggregate to aggregate must be the same type, or the String/byte-
//     slice pair, whose layouts are identical by construction ({ptr, len}
//     in both, same order under auto layout) - the coercion is a retype.
//   - A class mismatch (an array decaying to a slice, a slice coercing to
//     its data pointer) changes representation. Emitting the bytes as-is
//     would be silently wrong, so the caller refuses.
fn repr_compatible(ctx: &LowerCtx, src: &Ty, dst: &Ty) bool {
    if src.* == dst.* {
        return true
    }
    let sa = is_by_ref(ctx, src)
    let da = is_by_ref(ctx, dst)
    if sa != da {
        return false
    }
    if !sa {
        return true
    }
    if string_byte_slice_pair(ctx, src, dst) {
        return true
    }
    // A `Type(T)` value IS a TypeInfo (minimal RTTI, M11).
    return type_typeinfo_pair(ctx, src, dst)
}

fn type_typeinfo_pair(ctx: &LowerCtx, a: &Ty, b: &Ty) bool {
    if nominal_fqn_is(ctx, a, FQN_TYPE) {
        return nominal_fqn_is(ctx, b, FQN_TYPE_INFO)
    }
    if nominal_fqn_is(ctx, b, FQN_TYPE) {
        return nominal_fqn_is(ctx, a, FQN_TYPE_INFO)
    }
    return false
}

fn nominal_fqn_is(ctx: &LowerCtx, ty: &Ty, fqn: String) bool {
    let nr = tn(ctx, ty.*) match {
        NNominal(n) => n
        _ => return false
    }
    return ctx.result.nominals.get(nr.id).* match {
        NomStruct(st) => st.fqn == fqn
        NomEnum(e) => e.fqn == fqn
    }
}

fn string_byte_slice_pair(ctx: &LowerCtx, a: &Ty, b: &Ty) bool {
    if is_string_ty(ctx, a) {
        return is_byte_slice_ty(ctx, b)
    }
    if is_string_ty(ctx, b) {
        return is_byte_slice_ty(ctx, a)
    }
    return false
}

fn is_string_ty(ctx: &LowerCtx, ty: &Ty) bool {
    let nr = tn(ctx, ty.*) match {
        NNominal(n) => n
        _ => return false
    }
    let id = ctx.result.nominals.by_fqn.get(FQN_STRING)
    if id.is_none() {
        return false
    }
    return id.unwrap() == nr.id
}

fn is_byte_slice_ty(ctx: &LowerCtx, ty: &Ty) bool {
    let nr = tn(ctx, ty.*) match {
        NNominal(n) => n
        _ => return false
    }
    let id = ctx.result.nominals.by_fqn.get(FQN_SLICE)
    if id.is_none() {
        return false
    }
    if id.unwrap() != nr.id {
        return false
    }
    if nr.args.len != 1 {
        return false
    }
    return tyit(ctx).child_at(nr.args, 0) == prim_of(PrimitiveKind.U8)
}

fn lower_literal(ctx: &LowerCtx, bb: &BlockBuilder, l: &LiteralExpr) Operand {
    l.value match {
        Null => {
            let ty = node_ty(ctx, l.span)
            return lower_null(ctx, bb, &ty)
        }
        String(s) => return lower_string_lit(ctx, bb, l.span, &s)
        Float(_) => {
            // The constant's consumers type their instructions from the node; a non-float node type
            // (an unresolved var, typically) would wrap the double in integer arithmetic - silently
            // wrong bytes, so refuse instead.
            let ty = node_ty(ctx, l.span)
            if !is_float(prim_kind_of_ty(ctx, ty)) {
                return unlowerable(ctx)
            }
        }
        _ => {}
    }
    if !literal_testable(&l.value) {
        return unlowerable(ctx)
    }
    return lower_literal_value(ctx, &l.value)
}

// A string literal is a `String { ptr, len }` view over its bytes in the data segment: intern the
// bytes as a global, then build the view into a stack slot exactly like a struct literal -
// per-field stores at the layout's offsets, the slot pointer is the value.
fn lower_string_lit(ctx: &LowerCtx, bb: &BlockBuilder, sp: SourceSpan, s: &StringLiteral) Operand {
    let ty = node_ty(ctx, sp)
    return build_string_view(ctx, bb, &ty, s)
}

// Build the `String { ptr, len }` view for a literal at a KNOWN type - shared between expression
// position (typed by the node) and pattern position (typed by the scrutinee, whose pattern node has
// no recorded type).
fn build_string_view(ctx: &LowerCtx, bb: &BlockBuilder, ty: &Ty, s: &StringLiteral) Operand {
    // The type must actually be `core.string.String` - handing these two fields to any other
    // recorded type would misread its layout.
    if !is_string_ty(ctx, ty) {
        return unlowerable(ctx)
    }
    let interned = intern_string(ctx, s.text)
    if interned.is_none() {
        return unlowerable(ctx)
    }
    let e = interned.unwrap()
    return build_slice_view(ctx, bb, ty, Operand.GlobalRef(e.name), e.len)
}

// The data-segment global for a literal's decoded bytes, minting one on first sight. Keyed by the
// RAW source text: repeat literals (the common case - 6,700 sites, heavy repetition) intern with
// zero decode work, at the cost of duplicate globals for two spellings of the same bytes. Returns
// null only when the text has a malformed escape.
//
// The decoded buffer, the null-terminated copy, and the global's name are deliberately leaked - the
// IrModule references them for the rest of the build, same as `fresh_label`'s labels.
fn intern_string(ctx: &LowerCtx, raw: String) StrData? {
    let hit = ctx.strings.get(raw)
    if hit.is_some() {
        return hit
    }

    let decoded = decode_string_text(raw, ctx.allocator)
    if decoded.is_none() {
        return null
    }
    let d = decoded.unwrap()

    // Data-segment bytes: decoded content plus a null terminator, so the `ptr` field satisfies
    // String's C-FFI contract (core/string.f).
    let buf = string_builder(d.len + 1, ctx.allocator)
    buf.append(d.as_view())
    buf.append_byte(0u8)
    let bytes = buf.to_string()

    let nb = string_builder(12, ctx.allocator)
    nb.append("str_")
    nb.append(ctx.strings.len())
    let name = nb.to_string()
    nb.deinit()

    ctx.str_globals.push(Global {
        name = name.as_view(),
        size = (d.len + 1) as u64,
        align = 1u64,
        init_bytes = Some(bytes.as_view().as_raw_bytes()),
    })
    let entry = StrData { name = name.as_view(), len = d.len }
    ctx.strings.set(raw, entry)
    d.deinit()
    return Some(entry)
}

// Move the interned string globals into the module once the walk is done. Part of `lower_module` /
// `lower_program`, split out so both share it.
fn flush_strings(m: &IrModule, ctx: &LowerCtx) {
    for i in 0..ctx.str_globals.len {
        m.add_global(ctx.str_globals[i])
    }
    ctx.str_globals.deinit()
    ctx.strings.deinit()
}

// `null` is `Option.None` of the node's type. The niche form is the null pointer; the tagged form
// is a zeroed buffer - `None` is declared first in core.option, so tag 0 is None by construction (a
// documented invariant there).
fn lower_null(ctx: &LowerCtx, bb: &BlockBuilder, ty: &Ty) Operand {
    if niche_optional(ctx, ty) {
        return Operand.NullPtr
    }
    if is_by_ref(ctx, ty) {
        let lay = layout_of(tyit(ctx), ty.*, &ctx.result.nominals, ctx.allocator)
        let slot = bb.stack_slot(lay.size as u64, lay.align as u64)
        bb.memset(slot, Operand.IntConst(0), Operand.IntConst(lay.size as i64))
        return slot
    }
    // A null with a non-optional type is an already-reported checker error.
    return Operand.NullPtr
}

// A literal form's FIR constant. Shared with pattern tests, where the same forms appear without an
// enclosing expression node.
fn lower_literal_value(ctx: &LowerCtx, v: &LiteralValue) Operand {
    return v.* match {
        Int(i) => Operand.IntConst(parse_int(i.text))
        Float(f) => Operand.FloatConst(parse_float(f.text))
        Bool(b) => Operand.IntConst(if b.value { 1 } else { 0 })
        Char(c) => char_const(ctx, c.text)
        Byte(by) => char_const(ctx, by.text)
        // String is handled by `lower_string_lit` before this is reached (and is not testable in
        // patterns). Null is type-directed - see `lower_null` and the null arm of `literal_test`.
        _ => Operand.IntConst(0)
    }
}

// Reading a name: a scalar loads from its slot; an aggregate yields its address, since FIR
// addresses aggregates by pointer. `expect` is the use site's recorded type - when it disagrees
// with the binding's own type in representation (a coercion the checker applied), the read refuses
// rather than pass the binding's bytes off as something they are not.
fn read_binding(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, name: String, expect: &Ty) Operand {
    let found = env.get(name)
    if found.is_none() {
        return unlowerable_about(ctx, "unbound name read", name)
    }
    let b = found.unwrap()
    if !repr_compatible(ctx, &b.src, expect) {
        return unlowerable(ctx)
    }
    if b.aggregate {
        return b.addr
    }
    return bb.load(b.ty, b.addr)
}

fn lower_identifier(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, id: &IdentifierExpr) Operand {
    // A bare payload-less variant (`None`, an unqualified `Red`) is construction, not a binding
    // read. Locals shadow variants in the checker, so a shadowed name carries `RtLocal` and falls
    // through.
    let vnum = resolved_variant(ctx, id.span)
    if vnum.is_some() {
        return lower_variant_nullary(ctx, bb, id.span, vnum.unwrap())
    }
    let want = node_ty(ctx, id.span)
    // A function NAME in value position decays to its address (RFC-014 fn values); a module-const
    // read goes through its global (M11). Locals shadow both, so the env is consulted first.
    if env.get(id.name).is_none() {
        let tgt = ctx_target(ctx, node_id_of(id.span))
        if tgt.is_some() {
            tgt.unwrap() match {
                RtFunction(f) => {
                    let s = ctx.syms.lookup_symbol(f)
                    if s.is_some() {
                        return Operand.FuncRef(s.unwrap())
                    }
                }
                // An overloaded name resolved to a generic winner
                // (ticket 019 §4) decays to its specialization.
                RtSpecialized(sid) => {
                    let s2 = ctx.syms.spec_symbol(sid)
                    if s2.is_some() {
                        return Operand.FuncRef(s2.unwrap())
                    }
                }
                RtConst(fqn) => return read_const(ctx, bb, fqn, &want)
                _ => {}
            }
        }
        // A bare type name in value position (`size_of(St)`-shape args that no intercept folded) is
        // a reified-type handle.
        if nominal_fqn_is(ctx, &want, FQN_TYPE) {
            return build_typeinfo_value(ctx, bb, &want)
        }
    }
    return read_binding(ctx, bb, env, id.name, &want)
}

// A comparison dispatched to a user operator function (M11): emit the call, then apply the record's
// post-processing - negation (`!=` from `op_eq`), or an Ord-tag compare (`<` etc. from `op_cmp`;
// Ord's tags are fixed at Less=-1 / Equal=0 / Greater=1, so the derived compare is the signed tag
// against zero).
fn lower_operator_binary(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, b: &BinaryExpr,
    op: &ResolvedOperator) Operand {
    let sym = op_symbol(ctx, op)
    let sig = op_sig(ctx, op)
    if sym.is_none() or sig.is_none() {
        return unlowerable_why(ctx, "binary operator without symbol")
    }
    let g = sig.unwrap()
    if g.params.len != 2 {
        return unlowerable(ctx)
    }
    let lty = node_ty(ctx, expr_span(b.lhs))
    let rty = node_ty(ctx, expr_span(b.rhs))
    if !repr_compatible(ctx, &lty, &g.params[0]) {
        return unlowerable(ctx)
    }
    if !repr_compatible(ctx, &rty, &g.params[1]) {
        return unlowerable(ctx)
    }

    let args: List(Operand) = list(3, ctx.allocator)
    args.push(lower_expr(ctx, bb, env, b.lhs))
    args.push(lower_expr(ctx, bb, env, b.rhs))
    let res = emit_call(ctx, bb, sym.unwrap(), &g, args)

    if op.cmp_derived_op.is_some() {
        // `op_cmp` returns Ord - an aggregate; its address came back from the sret path. The
        // derived comparison reads the tag and tests it against the variant INDICES resolved from
        // Ord's definition - this lowering stores declaration indices as tags (explicit variant
        // values like `Less = -1` are not honored yet; see docs/known-issues.md), so the test must
        // use the same scheme.
        let t = resolve_enum(ctx, &g.ret, &ctx.result.nominals)
        if t.is_none() {
            return unlowerable(ctx)
        }
        let et = t.unwrap()
        let less = variant_index_of(&et.def, "Less")
        let equal = variant_index_of(&et.def, "Equal")
        let greater = variant_index_of(&et.def, "Greater")
        if less.is_none() or equal.is_none() or greater.is_none() {
            return unlowerable(ctx)
        }
        let lo = Operand.IntConst(less.unwrap() as i64)
        let eq = Operand.IntConst(equal.unwrap() as i64)
        let hi = Operand.IntConst(greater.unwrap() as i64)
        let tag = bb.load(IrType.I32, res)
        return op.cmp_derived_op.unwrap() match {
            BodEq => bb.icmp_eq(IrType.I32, tag, eq)
            BodNe => bb.icmp_ne(IrType.I32, tag, eq)
            BodLt => bb.icmp_eq(IrType.I32, tag, lo)
            BodGt => bb.icmp_eq(IrType.I32, tag, hi)
            // `<=` is "not Greater", `>=` is "not Less".
            BodLe => bb.icmp_ne(IrType.I32, tag, hi)
            BodGe => bb.icmp_ne(IrType.I32, tag, lo)
        }
    }
    if op.negate_result {
        return bb.icmp_eq(IrType.I8, res, Operand.IntConst(0))
    }
    return res
}

fn variant_index_of(def: &EnumDef, name: String) u32? {
    for i in 0..def.variants.len {
        if def.variants[i].name == name {
            return Some(i as u32)
        }
    }
    return null
}

fn payloadless_enum_ty(ctx: &LowerCtx, ty: &Ty) bool {
    return tn(ctx, ty.*) match {
        NNominal(nn) => enum_payloadless(&ctx.result.nominals, nn.id)
        _ => false
    }
}

fn lower_binary(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, b: &BinaryExpr) Operand {
    // `and`/`or` branch, so the right operand must not be lowered into the current block alongside
    // the left.
    b.op match {
        And => return lower_short_circuit(ctx, bb, env, b, true)
        Or => return lower_short_circuit(ctx, bb, env, b, false)
        _ => {}
    }

    // A comparison the checker resolved to a user operator function (M11) dispatches as a call -
    // `op_eq`/`op_cmp` and friends, with the negation and Ord-derivation the record carries.
    let rop = ctx_operator(ctx, node_id_of(b.span))
    if rop.is_some() {
        return lower_operator_binary(ctx, bb, env, b, &rop.unwrap())
    }

    let lty = node_ty(ctx, expr_span(b.lhs))
    let rty = node_ty(ctx, expr_span(b.rhs))
    if is_by_ref(ctx, &lty) or is_by_ref(ctx, &rty) {
        // Builtin `==`/`!=` on a payload-less enum: tag compare (the checker's fast path records no
        // operator for these).
        let eq_shape = b.op match { Eq => true, Ne => true, _ => false }
        if eq_shape and payloadless_enum_ty(ctx, &lty) and payloadless_enum_ty(ctx, &rty) {
            let la = lower_expr(ctx, bb, env, b.lhs)
            let ra = lower_expr(ctx, bb, env, b.rhs)
            let lt = bb.load(IrType.I32, la)
            let rt = bb.load(IrType.I32, ra)
            let is_eq = b.op match { Eq => true, _ => false }
            if is_eq {
                return bb.icmp_eq(IrType.I32, lt, rt)
            }
            return bb.icmp_ne(IrType.I32, lt, rt)
        }
        // Any other operator over aggregates has no recorded dispatch - FIR arithmetic over the
        // addresses would be silently wrong.
        return unlowerable_why(ctx, "operator over aggregates without dispatch")
    }

    // Pointer arithmetic scales by the POINTEE size: `p + n` advances n ELEMENTS (spec 2.9). FIR
    // geps are byte offsets - the C backend does char* math, so the scaling the reference gets from
    // typed C pointers must be explicit here. Emitting an unscaled add was a silent miscompile for
    // any pointee wider than a byte.
    let l_inner = tn(ctx, lty) match {
        NRef(i) => Some(i)
        _ => null
    }
    if l_inner.is_some() {
        let is_addsub = b.op match { Add => true, Sub => true, _ => false }
        let rhs_int = is_int_prim(ctx, rty)
        if is_addsub and rhs_int {
            let esize = layout_of(tyit(ctx), l_inner.unwrap(), &ctx.result.nominals,
                ctx.allocator).size
            let base = lower_expr(ctx, bb, env, b.lhs)
            let count = lower_expr(ctx, bb, env, b.rhs)
            let off = bb.imul(IrType.I64, count, Operand.IntConst(esize as i64))
            let is_sub = b.op match { Sub => true, _ => false }
            if is_sub {
                off = bb.isub(IrType.I64, Operand.IntConst(0), off)
            }
            return bb.gep(base, off)
        }
    }

    let lhs = lower_expr(ctx, bb, env, b.lhs)
    let rhs = lower_expr(ctx, bb, env, b.rhs)
    let ty = node_ty(ctx, b.span)
    let ir = ty_to_ir(ctx, ty)
    let p = prim_kind_of_ty(ctx, ty)
    let fl = is_float(p)
    let sg = is_signed_integer(p)
    // A comparison is typed by its operands, not by its `bool` result.
    let oty = node_ty(ctx, expr_span(b.lhs))
    let op_ir = ty_to_ir(ctx, oty)
    let op_p = prim_kind_of_ty(ctx, oty)
    let ofl = is_float(op_p)
    let osg = is_signed_integer(op_p)
    return b.op match {
        Add => bb.add_op(ir, fl, lhs, rhs)
        Sub => bb.sub_op(ir, fl, lhs, rhs)
        Mul => bb.mul_op(ir, fl, lhs, rhs)
        Div => bb.div_op(ir, fl, sg, lhs, rhs)
        Mod => bb.mod_op(ir, sg, lhs, rhs)
        BitAnd => bb.iand(ir, lhs, rhs)
        BitOr => bb.ior(ir, lhs, rhs)
        BitXor => bb.ixor(ir, lhs, rhs)
        Shl => bb.ishl(ir, lhs, rhs)
        Shr => bb.shr_op(ir, sg, lhs, rhs)
        UShr => bb.ushr(ir, lhs, rhs)
        Eq => if ofl { bb.fcmp_eq(op_ir, lhs, rhs) } else { bb.icmp_eq(op_ir, lhs, rhs) }
        Ne => if ofl { bb.fcmp_ne(op_ir, lhs, rhs) } else { bb.icmp_ne(op_ir, lhs, rhs) }
        Lt => bb.lt_op(op_ir, ofl, osg, lhs, rhs)
        Le => bb.le_op(op_ir, ofl, osg, lhs, rhs)
        Gt => bb.gt_op(op_ir, ofl, osg, lhs, rhs)
        Ge => bb.ge_op(op_ir, ofl, osg, lhs, rhs)
        // Handled above; unreachable.
        And => Operand.IntConst(0)
        Or => Operand.IntConst(0)
    }
}

// `a and b` / `a or b`. `b` is evaluated only when `a` leaves the result undecided; the deciding
// constant (false for `and`, true for `or`) rides the short-circuit edge into the join as a block
// argument.
fn lower_short_circuit(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, b: &BinaryExpr,
    is_and: bool) Operand {
    let lhs = lower_expr(ctx, bb, env, b.lhs)

    let fb = bb.fb
    let rhs_bb = fb.block(fb.fresh_label("sc_rhs"))
    let join = fb.block(fb.fresh_label("sc_join"), IrType.I8)

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
    bb.br_arg(join.label(), rhs)

    bb.move_to(&join)
    return join.param(0)
}

fn lt_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl {
        return bb.fcmp_lt(ir, lhs, rhs)
    }
    if sg {
        return bb.icmp_slt(ir, lhs, rhs)
    }
    return bb.icmp_ult(ir, lhs, rhs)
}

fn le_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl {
        return bb.fcmp_le(ir, lhs, rhs)
    }
    if sg {
        return bb.icmp_sle(ir, lhs, rhs)
    }
    return bb.icmp_ule(ir, lhs, rhs)
}

fn gt_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl {
        return bb.fcmp_gt(ir, lhs, rhs)
    }
    if sg {
        return bb.icmp_sgt(ir, lhs, rhs)
    }
    return bb.icmp_ugt(ir, lhs, rhs)
}

fn ge_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl {
        return bb.fcmp_ge(ir, lhs, rhs)
    }
    if sg {
        return bb.icmp_sge(ir, lhs, rhs)
    }
    return bb.icmp_uge(ir, lhs, rhs)
}

fn add_op(bb: &BlockBuilder, ir: IrType, fl: bool, lhs: Operand, rhs: Operand) Operand {
    if fl {
        return bb.fadd(ir, lhs, rhs)
    }
    return bb.iadd(ir, lhs, rhs)
}

fn sub_op(bb: &BlockBuilder, ir: IrType, fl: bool, lhs: Operand, rhs: Operand) Operand {
    if fl {
        return bb.fsub(ir, lhs, rhs)
    }
    return bb.isub(ir, lhs, rhs)
}

fn mul_op(bb: &BlockBuilder, ir: IrType, fl: bool, lhs: Operand, rhs: Operand) Operand {
    if fl {
        return bb.fmul(ir, lhs, rhs)
    }
    return bb.imul(ir, lhs, rhs)
}

fn div_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if is_const_zero(&rhs) {
        return Operand.IntConst(0)
    }
    if fl {
        return bb.fdiv(ir, lhs, rhs)
    }
    if sg {
        return bb.sdiv(ir, lhs, rhs)
    }
    return bb.udiv(ir, lhs, rhs)
}

fn mod_op(bb: &BlockBuilder, ir: IrType, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if is_const_zero(&rhs) {
        return Operand.IntConst(0)
    }
    if sg {
        return bb.srem(ir, lhs, rhs)
    }
    return bb.urem(ir, lhs, rhs)
}

// A literal zero divisor is a constant expression C refuses to compile; placeholder lowering
// produces them, so dividing by one lowers to a placeholder value too.
fn is_const_zero(op: &Operand) bool {
    return op.* match {
        IntConst(n) => n == 0
        _ => false
    }
}

fn shr_op(bb: &BlockBuilder, ir: IrType, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if sg {
        return bb.sshr(ir, lhs, rhs)
    }
    return bb.ushr(ir, lhs, rhs)
}

fn lower_unary(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, u: &UnaryExpr) Operand {
    // Same as `lower_binary`: a user-defined operator over an aggregate is not recorded on the
    // node, so it refuses.
    let oty = node_ty(ctx, expr_span(u.operand))
    if is_by_ref(ctx, &oty) {
        return unlowerable(ctx)
    }
    let v = lower_expr(ctx, bb, env, u.operand)
    let ty = node_ty(ctx, u.span)
    let ir = ty_to_ir(ctx, ty)
    let p = prim_kind_of_ty(ctx, ty)
    return u.op match {
        Neg => bb.neg_op(ir, is_float(p), v)
        BitNot => bb.ixor(ir, v, Operand.IntConst(-1))
        // `!b` is `b == 0`; bool is a byte in FIR, so no widening.
        Not => bb.icmp_eq(ir, v, Operand.IntConst(0))
    }
}

fn neg_op(bb: &BlockBuilder, ir: IrType, fl: bool, v: Operand) Operand {
    if fl {
        return bb.fneg(ir, v)
    }
    return bb.ineg(ir, v)
}

// Result-table reads (M10: overlay-aware)
//
// While a specialization lowers, its overlay holds the instantiation's entries for the shared
// template body nodes; the program tables are the fallback for everything else (checker-synthesized
// desugar nodes, nodes outside the body).

fn ctx_type(ctx: &LowerCtx, id: NodeId) Ty? {
    ctx.overlay match {
        Some(ov) => {
            let t = ov.get_type(id)
            if t.is_some() {
                return t
            }
        }
        None => {}
    }
    return ctx.result.get_type(id)
}

fn ctx_target(ctx: &LowerCtx, id: NodeId) ResolvedTarget? {
    ctx.overlay match {
        Some(ov) => {
            let t = ov.resolved_targets.get(id)
            if t.is_some() {
                return t
            }
        }
        None => {}
    }
    return ctx.result.get_target(id)
}

// The checked lambda record for the literal at `id`, through the active overlay first (a template
// body's lambda records once per instantiation).
fn ctx_lambda(ctx: &LowerCtx, id: NodeId) &LambdaInfo? {
    ctx.overlay match {
        Some(ov) => {
            let l = ov.lambdas.get_ref(id)
            if l.is_some() {
                return l
            }
        }
        None => {}
    }
    return ctx.result.get_lambda(id)
}

fn ctx_operator(ctx: &LowerCtx, id: NodeId) ResolvedOperator? {
    ctx.overlay match {
        Some(ov) => {
            let o = ov.resolved_ops.get(id)
            if o.is_some() {
                return o
            }
        }
        None => {}
    }
    return ctx.result.get_operator(id)
}

// A resolved operator's callable: the specialization when the pick was generic (M10), the
// function's own symbol otherwise.
fn op_symbol(ctx: &LowerCtx, o: &ResolvedOperator) String? {
    return o.spec_id match {
        Some(sid) => ctx.syms.spec_symbol(sid)
        None => ctx.syms.lookup_symbol(o.function_id)
    }
}

fn op_sig(ctx: &LowerCtx, o: &ResolvedOperator) FnSig? {
    return o.spec_id match {
        Some(sid) => ctx.syms.spec_sig(sid)
        None => ctx.syms.sig_of(o.function_id)
    }
}

// The op_deref hops of the UFCS call at `id` (checker's `deref_retry`) - through the active overlay
// first, like every table read.
fn ctx_receiver_deref(ctx: &LowerCtx, id: NodeId) &List(ResolvedTarget)? {
    ctx.overlay match {
        Some(ov) => {
            let d = ov.receiver_derefs.get_ref(id)
            if d.is_some() {
                return d
            }
        }
        None => {}
    }
    return ctx.result.get_receiver_deref(id)
}

// The materialized default arguments for the call at `id` (M11) - through the active overlay first
// (a call inside a template body records per instantiation). Whether any argument of `call` is
// written `name = value`.
fn call_has_named(call: &CallExpr) bool {
    for i in 0..call.args.len {
        call.args[i] match {
            Named(_) => return true
            _ => {}
        }
    }
    return false
}

// The complete parameter-ordered argument list for the call at `id` (M12), through the active
// overlay first like every table read.
fn ctx_arg_list(ctx: &LowerCtx, id: NodeId) &List(Expr)? {
    ctx.overlay match {
        Some(ov) => {
            let a = ov.arg_lists.get_ref(id)
            if a.is_some() {
                return a
            }
        }
        None => {}
    }
    return ctx.result.get_arg_list(id)
}

fn ctx_default_args(ctx: &LowerCtx, id: NodeId) &List(Expr)? {
    ctx.overlay match {
        Some(ov) => {
            let d = ov.default_args.get_ref(id)
            if d.is_some() {
                return d
            }
        }
        None => {}
    }
    return ctx.result.get_default_args(id)
}

fn ctx_desugar(ctx: &LowerCtx, id: NodeId) &BlockExpr? {
    ctx.overlay match {
        Some(ov) => {
            let d = ov.desugars.get(id)
            if d.is_some() {
                return d
            }
        }
        None => {}
    }
    return ctx.result.get_desugar(id)
}

// Type mapping

// The resolved type of the AST node at `span`, falling back to `i32` when the checker never
// recorded one (unparsed/erroneous input).
fn node_ty(ctx: &LowerCtx, span: SourceSpan) Ty {
    let t = ctx_type(ctx, node_id_of(span))
    if t.is_some() {
        return t.unwrap()
    }
    return prim_of(PrimitiveKind.I32)
}

// A resolved `Ty` to its FIR scalar type. References and function values are pointers; other
// non-scalar shapes fold to `i64` so placeholder arithmetic over a still-refused construct emits
// compilable C. An unresolved type variable is different: since M10 every lowered body is concrete,
// so a `Var` here is a checker bug, not a subset gap - fail loudly rather than bake a guessed width
// into real code.
fn ty_to_ir(ctx: &LowerCtx, ty: Ty) IrType {
    return tn(ctx, ty) match {
        NPrim(p) => prim_ir(p)
        NRef(_) => IrType.Ptr
        NFunc(_) => IrType.Ptr
        NVar(_) => panic("unresolved type variable reached lowering - checker bug")
        _ => IrType.I64
    }
}

// FIR has no unsigned or boolean primitives - signedness is a per-op choice, and bool is a byte. So
// unsigned/char/size kinds fold onto the same-width signed FIR scalar.
fn prim_ir(p: PrimitiveKind) IrType {
    return p match {
        Bool => IrType.I8
        I8 => IrType.I8
        U8 => IrType.I8
        I16 => IrType.I16
        U16 => IrType.I16
        I32 => IrType.I32
        U32 => IrType.I32
        Char => IrType.I32
        I64 => IrType.I64
        U64 => IrType.I64
        ISize => IrType.I64
        USize => IrType.I64
        F32 => IrType.F32
        F64 => IrType.F64
    }
}

fn type_expr_is_never(te: &TypeExpr) bool {
    return te.* match {
        Named(n) => n.name == "never"
        _ => false
    }
}

// A signature `TypeExpr` to its FIR scalar type, or null when the type is outside this milestone's
// scope (aggregates, optionals, generics).
fn type_expr_to_ir(te: &TypeExpr) IrType? {
    return te.* match {
        Named(n) => named_to_ir(n.name)
        Reference(_) => Some(IrType.Ptr)
        // `&T?` - the pointer-niche Option is a nullable pointer, the C idiom foreign signatures
        // actually mean (`malloc`'s return). The tagged form (`usize?`) stays unspellable for
        // externs.
        Optional(o) => o.inner.* match {
            Reference(_) => Some(IrType.Ptr)
            _ => null
        }
        _ => null
    }
}

fn named_to_ir(name: String) IrType? {
    if name == "i8" {
        return Some(IrType.I8)
    }
    if name == "u8" {
        return Some(IrType.I8)
    }
    if name == "bool" {
        return Some(IrType.I8)
    }
    if name == "i16" {
        return Some(IrType.I16)
    }
    if name == "u16" {
        return Some(IrType.I16)
    }
    if name == "i32" {
        return Some(IrType.I32)
    }
    if name == "u32" {
        return Some(IrType.I32)
    }
    if name == "char" {
        return Some(IrType.I32)
    }
    if name == "i64" {
        return Some(IrType.I64)
    }
    if name == "u64" {
        return Some(IrType.I64)
    }
    if name == "isize" {
        return Some(IrType.I64)
    }
    if name == "usize" {
        return Some(IrType.I64)
    }
    if name == "f32" {
        return Some(IrType.F32)
    }
    if name == "f64" {
        return Some(IrType.F64)
    }
    return null
}

// The primitive kind behind a handle, defaulting to i32 for the placeholder paths - the
// lowering-local sibling of type.f's `prim_of`.
fn prim_kind_of_ty(ctx: &LowerCtx, ty: Ty) PrimitiveKind {
    return tn(ctx, ty) match {
        NPrim(p) => p
        _ => PrimitiveKind.I32
    }
}

// Literal parsing

// Parse an integer literal's source text (decimal, `0x`, or `0b`, with `_` digit separators) into
// its value. Suffixes are stripped by the lexer, so `text` is digits only.
fn parse_int(text: String) i64 {
    let base: i64 = 10
    let i: usize = 0
    if text.len >= 2 {
        if text[0] == '0' {
            if text[1] == 'x' {
                base = 16
                i = 2
            }
            if text[1] == 'b' {
                base = 2
                i = 2
            }
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
    if c >= '0' and c <= '9' {
        return (c - '0') as i64
    }
    if c >= 'a' and c <= 'f' {
        return ((c - 'a') + 10) as i64
    }
    if c >= 'A' and c <= 'F' {
        return ((c - 'A') + 10) as i64
    }
    return 0
}

// Parse a float literal's source text (`3.14`, `1.5e10`, `1_000.5`, with `_` digit separators) into
// its f64 value. Suffixes are stripped by the lexer, so `text` is the numeric form only.
//
// ponytail: digit-by-digit accumulation - exact while the mantissa fits 2^53 and the power of ten
// stays within 10^22; larger scales apply in exact 10^22 chunks (one rounding each). A
// 20-significant-digit literal may land an ulp or two off the correctly-rounded value, and a
// literal within a few ulp of DBL_MAX can still round over into infinity - the in-tree DBL_MAX
// guards were rewritten to `v * 0.5 == v` for exactly that reason. Upgrade to a strtod-grade
// algorithm if a literal ever needs that last ulp.
fn parse_float(text: String) f64 {
    let i: usize = 0
    let mant: f64 = 0.0
    while i < text.len {
        const c = text[i]
        if c == '_' {
            i = i + 1
            continue
        }
        if c < '0' or c > '9' {
            break
        }
        mant = mant * 10.0 + (digit_val(c) as f64)
        i = i + 1
    }
    let scale: i64 = 0
    if i < text.len and text[i] == '.' {
        i = i + 1
        while i < text.len {
            const c = text[i]
            if c == '_' {
                i = i + 1
                continue
            }
            if c < '0' or c > '9' {
                break
            }
            mant = mant * 10.0 + (digit_val(c) as f64)
            scale = scale - 1
            i = i + 1
        }
    }
    if i < text.len and (text[i] == 'e' or text[i] == 'E') {
        i = i + 1
        let neg_exp = false
        if i < text.len and (text[i] == '+' or text[i] == '-') {
            neg_exp = text[i] == '-'
            i = i + 1
        }
        let e: i64 = 0
        while i < text.len {
            const c = text[i]
            if c == '_' {
                i = i + 1
                continue
            }
            if c < '0' or c > '9' {
                break
            }
            e = e * 10 + digit_val(c)
            i = i + 1
        }
        if neg_exp {
            scale = scale - e
        } else {
            scale = scale + e
        }
    }
    if scale == 0 {
        return mant
    }
    // Divide for negative scales rather than multiply by a tiny power: 10^-k is inexact, 10^k (k <=
    // 22) is exact, and one division rounds once. Scales beyond 22 apply in exact 10^22 chunks -
    // one rounding per chunk instead of one per decimal digit, which is what kept a
    // DBL_MAX-magnitude literal from tipping over into infinity.
    let k = scale
    if k < 0 {
        k = 0 - k
    }
    let acc = mant
    while k > 22 {
        if scale < 0 {
            acc = acc / 1.0e22
        } else {
            acc = acc * 1.0e22
        }
        k = k - 22
    }
    let p: f64 = 1.0
    let j: i64 = 0
    while j < k {
        p = p * 10.0
        j = j + 1
    }
    if scale < 0 {
        return acc / p
    }
    return acc * p
}

// A char/byte literal's codepoint constant. The lexer validates the form but keeps the raw source
// text (escapes included, quotes stripped), so the decode happens here; a form the decoder cannot
// handle refuses the function rather than emit the wrong constant.
fn char_const(ctx: &LowerCtx, text: String) Operand {
    let v = decode_char(text)
    if v.is_none() {
        return unlowerable(ctx)
    }
    return Operand.IntConst(v.unwrap())
}

// Mirrors the lexer's `lex_char_literal`: simple escapes via the same table (unknown escapes yield
// the escaped byte), `\u` hex escapes, and raw UTF-8 decoded to the codepoint.
fn decode_char(text: String) i64? {
    if text.len == 0 {
        return null
    }
    if text[0] == '\\' {
        if text.len < 2 {
            return null
        }
        let e = text[1]
        if e == 'u' {
            return decode_hex(text, 2)
        }
        if e == 'n' {
            return Some(10)
        }
        if e == 't' {
            return Some(9)
        }
        if e == 'r' {
            return Some(13)
        }
        if e == '0' {
            return Some(0)
        }
        // Unknown escapes pass the escaped byte through, matching `decode_simple_escape` (covers
        // `\\`, `\'`, `\"` too).
        return Some(e as i64)
    }
    let b0 = text[0]
    if b0 < 0x80 {
        if text.len != 1 {
            return null
        }
        return Some(b0 as i64)
    }
    // Multi-byte UTF-8 scalar.
    if b0 >= 0xF0 {
        return decode_utf8(text, (b0 & 0x07) as i64, 4)
    }
    if b0 >= 0xE0 {
        return decode_utf8(text, (b0 & 0x0F) as i64, 3)
    }
    if b0 >= 0xC0 {
        return decode_utf8(text, (b0 & 0x1F) as i64, 2)
    }
    // A stray continuation byte - the lexer should have rejected it.
    return null
}

fn decode_utf8(text: String, lead: i64, total: usize) i64? {
    if text.len != total {
        return null
    }
    let cp = lead
    for i in 1..total {
        let c = text[i]
        let masked = c & 0xC0
        if masked != 0x80 {
            return null
        }
        cp = cp * 64 + ((c & 0x3F) as i64)
    }
    return Some(cp)
}

fn decode_hex(text: String, start: usize) i64? {
    if start >= text.len {
        return null
    }
    let v: i64 = 0
    for i in start..text.len {
        v = v * 16 + digit_val(text[i])
    }
    return Some(v)
}

// Tests

// The callee of the first call instruction in `f`, or "" when it emits none. Test helper.
fn first_callee(f: &Function) String {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match {
                Call(c) => c.callee
                _ => ""
            }
            if hit.len > 0 {
                return hit
            }
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
                Call(c) => c.args.len + 1
                _ => 0 as usize
            }
            if n > 0 {
                return n - 1
            }
        }
    }
    return 0
}

// First function whose symbol starts with `prefix`. Type tokens embed the nominal's FQN, which
// depends on the analysed module's name, so tests that mention a user type match on the prefix
// rather than the whole symbol. Whether a symbol starting with `prefix` was refused rather than
// emitted. TEMPORARY SCAFFOLD (see `unlowerable`): delete with the skip mechanism.
fn was_skipped(m: &IrModule, prefix: String) bool {
    for n in m.skipped {
        if n.len >= prefix.len {
            if n[0..prefix.len] == prefix {
                return true
            }
        }
    }
    return false
}

fn find_fn_starting(m: &IrModule, prefix: String) usize {
    for i in 0..m.functions.len {
        let n = m.functions[i].name
        if n.len >= prefix.len {
            if n[0..prefix.len] == prefix {
                return i
            }
        }
    }
    return m.functions.len
}

fn find_fn(m: &IrModule, name: String) usize {
    for i in 0..m.functions.len {
        if m.functions[i].name == name {
            return i
        }
    }
    return m.functions.len
}

test "lowers a direct call to the callee's mangled symbol" {
    let unit = analyze(from_view("fn callee(a: i32) i32 { return a }\nfn main() i32 { return callee(7) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 2 as usize, "both functions lowered")
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "main was lowered")
    assert_true(first_callee(&m.functions[mi]) == "callee__i32",
        "call names the callee's signature symbol")
    assert_eq(first_call_argc(&m.functions[mi]), 1 as usize, "one argument passed")
}

test "a UFCS call passes the receiver as the first argument" {
    let unit = analyze(from_view("fn twice(a: i32) i32 { return a + a }\nfn main() i32 { let x = 5 return x.twice() }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "main was lowered")
    assert_true(first_callee(&m.functions[mi]) == "twice__i32",
        "UFCS resolves to the free function")
    assert_eq(first_call_argc(&m.functions[mi]), 1 as usize, "the receiver is the only argument")
}

test "a call site names the resolved overload's symbol, not the other one" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a }\nfn f(a: i32, b: i32) i32 { return a + b }\nfn main() i32 { return f(1, 2) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    let callee = first_callee(&m.functions[mi])
    // The call resolved to the two-parameter overload, so it must name that overload's symbol - and
    // that symbol must be defined in the module. Both sides read the one table, so they cannot
    // drift.
    assert_true(callee == "f__i32__i32", "the call names the two-parameter overload")
    assert_true(find_fn(&m, callee) < m.functions.len, "the named symbol is defined in the module")
    assert_true(find_fn(&m, "f__i32") < m.functions.len,
        "the one-parameter overload is defined too")
}

test "a caller of an out-of-subset callee is refused, not emitted with a stub" {
    let unit = analyze(from_view("fn takes_slice(xs: i32[]) i32 { return 0 }\nfn main() i32 { return takes_slice([1]) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    // The callee's signature never lowered, so there is no definition to link against. Emitting
    // `main` with a placeholder in place of the call would produce a binary that runs and returns
    // the wrong number.
    assert_true(find_fn(&m, "main") == m.functions.len, "main is not emitted")
    assert_true(was_skipped(&m, "main"), "and it is recorded as skipped")
}

test "a body-less declaration becomes a foreign decl calls can name" {
    let unit = analyze(from_view("#foreign fn puts(s: &u8) i32\nfn main() i32 { return 0 }"),
        "test.f")
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
            Binary(bi) => bi.op match { IAdd => has_add = true, _ => {} }
            _ => {}
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
                if l_const and r_const {
                    saw_consts = true
                }
            }
            _ => {}
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
            Binary(bi) => bi.op match { IAdd => adds = adds + 1, _ => {} }
            _ => {}
        }
    }
    assert_eq(adds as usize, 2 as usize, "let init and the return each add")
}

test "skips a function with an unsupported signature type" {
    let unit = analyze(from_view("fn takes_slice(xs: i32[]) i32 { return 0 }\nfn ok() i32 { return 1 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "only the scalar function is lowered")
    let f = &m.functions[0]
    assert_true(f.name == "ok", "the slice-taking function was skipped")
}

// Whether every byte of `s` is legal in a C identifier.
fn is_c_identifier(s: String) bool {
    if s.len == 0 {
        return false
    }
    for i in 0..s.len {
        let c = s[i]
        let ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (c >= '0'
            and c <= '9')
        if !ok {
            return false
        }
        if i == 0 {
            if c >= '0' and c <= '9' {
                return false
            }
        }
    }
    return true
}

test "a nominal parameter mangles to a valid C identifier" {
    // A nominal's token comes from its FQN, which carries dots. Emitting them raw would produce
    // `take__ref_test.Pt` - not a C identifier, and a syntax error rather than a link error.
    let unit = analyze(from_view("type Pt = struct { x: i32 }\nfn take(p: &Pt) i32 { return p.x }\nfn main() i32 { return 0 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(m.functions.len >= 2 as usize, "both functions lowered")
    for i in 0..m.functions.len {
        assert_true(is_c_identifier(m.functions[i].name),
            "every emitted symbol is a valid C identifier")
    }
}

test "lower_place addresses a nested path; lower_expr loads the scalar" {
    // The two entry points must NOT agree on a scalar member: the place is the field address, the
    // value is a load from it. A place context that reached for lower_expr would write through a
    // loaded scalar. See adr/0003.
    let unit = analyze(from_view("type I = struct { n: i32 }\ntype M = struct { i: I }\nfn main() i32 { let m = M { i = I { n = 3 } } return m.i.n }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "one function lowered")
    let f = &m.functions[0]

    // A two-hop read geps twice (outer field, then inner field) and loads once. A copied
    // intermediate would show up as an extra store/memcpy pair.
    let geps: usize = 0
    let loads: usize = 0
    let instrs = &f.blocks[0].instrs
    for i in 0..instrs.len {
        instrs[i] match {
            Gep(_) => geps = geps + 1
            Load(_) => loads = loads + 1
            _ => {}
        }
    }
    assert_true(geps >= 2 as usize, "the nested path geps through both hops")
    assert_eq(loads, 1 as usize, "only the final scalar is loaded")
}

test "lowers a struct field read to a slot store and an offset load" {
    let unit = analyze(from_view("type Pt = struct { x: i32, y: i32 }\nfn main() i32 { let p = Pt { x = 7, y = 4 } return p.y }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "one function lowered")
    let f = &m.functions[0]

    let has_slot = false
    let has_load = false
    let instrs = &f.blocks[0].instrs
    for i in 0..instrs.len {
        instrs[i] match {
            StackSlot(_) => has_slot = true
            Load(_) => has_load = true
            _ => {}
        }
    }
    assert_true(has_slot, "struct literal allocated a stack slot")
    assert_true(has_load, "field read emitted an offset load")
}

// Control flow test helpers.

// Index of the first block whose label starts with `prefix`, or the block count when there is none.
fn block_starting(f: &Function, prefix: String) usize {
    for i in 0..f.blocks.len {
        let l = f.blocks[i].label
        if l.len >= prefix.len {
            if l[0..prefix.len] == prefix {
                return i
            }
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
        Ret(v) => if v.is_some() { operand_local(v.unwrap()) } else { 0u32 }
        _ => 0u32
    }
}

// The slot a load producing `id` reads from, or 0 when `id` is not a load.
fn load_ptr(f: &Function, id: u32) u32 {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match {
                Load(l) => if l.result == id { Some(operand_local(l.ptr)) } else { null }
                _ => null
            }
            if hit.is_some() {
                return hit.unwrap()
            }
        }
    }
    return 0u32
}

fn compare_operand_ty(f: &Function) IrType {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match { Compare(c) => Some(c.operand_ty), _ => null }
            if hit.is_some() {
                return hit.unwrap()
            }
        }
    }
    return IrType.Ptr
}

test "an if expression joins its arms through a block parameter" {
    let unit = analyze(from_view("fn pick(a: i32) i32 { return if a > 0 { 1 } else { 2 } }"),
        "test.f")
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
    let unit = analyze(from_view("fn f(a: i32) i32 { if a > 0 { return 1 } else { return 2 } }"),
        "test.f")
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
    let unit = analyze(from_view("fn f(n: i32) i32 { while n > 0 { let x = n } return n }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let head = block_starting(f, "while_head")
    let body = block_starting(f, "while_body")
    assert_true(head < f.blocks.len, "a loop head exists")
    assert_true(ends_in_br_if(f, head), "the head tests the condition")
    assert_true(br_target(f, body) == f.blocks[head].label, "the body branches back to the head")
}

test "a for over a range carries the induction variable as a block parameter" {
    let unit = analyze(from_view("fn f(n: i32) i32 { for i in 0..n { let x = i } return n }"),
        "test.f")
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

// `..=` is pattern-only in FLang, so a range expression is always half-open; `range_cond` still
// honours the flag in case that changes.
test "a range bound is half-open" {
    let unit = analyze(from_view("fn f(n: i32) i32 { for i in 0..n { let x = i } return n }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let head = block_starting(f, "for_head")
    let instrs = &f.blocks[head].instrs
    let slt = false
    for i in 0..instrs.len {
        instrs[i] match {
            Compare(c) => c.op match { IcmpSlt => slt = true, _ => {} }
            _ => {}
        }
    }
    assert_true(slt, "the upper bound is exclusive")
}

test "break exits the loop and continue re-enters the latch" {
    let unit = analyze(from_view("fn f(n: i32) i32 { for i in 0..n { if i > 2 { break } else { continue } } return n }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let exit = f.blocks[block_starting(f, "for_exit")].label
    let latch = f.blocks[block_starting(f, "for_latch")].label
    assert_true(br_target(f, block_starting(f, "then")) == exit, "break leaves the loop")
    assert_true(br_target(f, block_starting(f, "else")) == latch,
        "continue advances the induction variable")
}

test "a for over a non-range iterable refuses the function" {
    let unit = analyze(from_view("fn f(xs: &i32) i32 { for x in xs { let y = 1 } return 0 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    // Silently dropping the loop would compile a function that skips work the source asked for.
    assert_true(find_fn_starting(&m, "f__ref_i32") == m.functions.len,
        "the function is not emitted")
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
    assert_eq(block_compare_count(f, rhs), 1 as usize,
        "the right operand's test is not in the entry block")
    assert_eq(block_compare_count(f, 0), 1 as usize,
        "and the left operand's test is not duplicated into it")
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
    // The shadowing literal is suffixed: an unsuffixed one with no use is E2001 since M10 (nothing
    // ever pins it).
    let unit = analyze(from_view("fn f(a: i32) i32 { let x = 1 if a > 0 { let x = 2i32 } return x }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    // Slots in emission order: the parameter, the outer `x`, then the shadowing `x` inside the
    // branch.
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
            if hit {
                return true
            }
        }
    }
    return false
}

// Whether `id` was produced by a call - i.e. names an operator's result.
fn is_call_result(f: &Function, id: u32) bool {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match { Call(c) => c.result match { Some(r) => r == id, None => false }, _ => false }
            if hit {
                return true
            }
        }
    }
    return false
}

fn call_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match { Call(_) => n = n + 1, _ => {} }
        }
    }
    return n
}

// The local the function's last `ret` hands back, or 0 when it returns nothing or returns a
// constant.
fn returned_local(f: &Function) u32 {
    let id: u32 = 0
    for b in 0..f.blocks.len {
        f.blocks[b].terminator match {
            Ret(v) => v match { Some(o) => id = operand_local(o), None => {} }
            _ => {}
        }
    }
    return id
}

// Whether `id` was produced by a load.
fn is_load_result(f: &Function, id: u32) bool {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match { Load(l) => l.result == id, _ => false }
            if hit {
                return true
            }
        }
    }
    return false
}

fn convert_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match { Convert(_) => n = n + 1, _ => {} }
        }
    }
    return n
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
    let unit = analyze(from_view("fn f(n: i32) i32 { let t = 0 for i in 0..n { t = t + i } return t }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let slots: List(u32) = list(4)
    collect_slots(f, &slots)
    // n, t, and the induction variable's per-iteration copy.
    assert_eq(slots.len, 3 as usize, "the accumulator is not re-slotted per iteration")
    assert_eq(last_store_ptr(f) as usize, slots[1] as usize,
        "the loop body writes the accumulator's slot")
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
    let unit = analyze(from_view("type P = struct { x: i32 y: i32 }\nfn f() i32 { let p = P { x = 1, y = 2 } p.x = 7 return p.x }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f")]
    assert_eq(memcpy_count(f), 0 as usize, "a scalar field assignment is a store, not a byte copy")
    // The struct literal also geps to initialize its fields, so counting geps proves nothing; what
    // matters is that the *assignment*'s store targets a field address rather than the local's own
    // slot.
    assert_true(is_gep_result(f, last_store_ptr(f)), "the write goes through a field address")
}

test "assigning an aggregate copies its bytes" {
    let unit = analyze(from_view("type P = struct { x: i32 y: i32 }\nfn f() i32 { let a = P { x = 1, y = 2 } let b = P { x = 3, y = 4 } b = a return b.x }"),
        "test.f")
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
            if l[0..prefix.len] == prefix {
                n = n + 1
            }
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

// `BinaryOp` is exported by both `ast` and `fir`, so it is never named in this file (see the
// header) - these match the variant instead.
fn has_ior_in(f: &Function, b: usize) bool {
    let instrs = &f.blocks[b].instrs
    for i in 0..instrs.len {
        let hit = instrs[i] match {
            Binary(bi) => bi.op match { IOr => true, _ => false }
            _ => false
        }
        if hit {
            return true
        }
    }
    return false
}

fn has_iand_in(f: &Function, b: usize) bool {
    let instrs = &f.blocks[b].instrs
    for i in 0..instrs.len {
        let hit = instrs[i] match {
            Binary(bi) => bi.op match { IAnd => true, _ => false }
            _ => false
        }
        if hit {
            return true
        }
    }
    return false
}

test "match on a scalar chains one test block per arm" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { 0 => 10, 1 => 20, _ => 30 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    assert_eq(block_count_starting(f, "m_arm"), 3 as usize, "one body block per arm")
    assert_eq(block_count_starting(f, "m_next"), 3 as usize,
        "each arm falls through to the next test")
    assert_eq(compare_count(f), 2 as usize, "the wildcard arm needs no compare")

    let join = block_starting(f, "m_join")
    assert_eq(f.blocks[join].params.len, 1 as usize, "the result crosses the join as a parameter")
}

test "the scrutinee is evaluated once, not per arm" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { 0 => 1, 1 => 2, _ => 3 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    // One load for the parameter's slot; the arms reuse that value.
    assert_eq(load_count(f), 1 as usize, "the scrutinee is loaded once for the whole match")
}

test "a match used as a statement carries no join parameter" {
    let unit = analyze(from_view("fn f(a: i32) i32 { a match { 0 => {}, _ => {} } return a }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let join = block_starting(f, "m_join")
    assert_true(join < f.blocks.len, "a join block exists")
    assert_eq(f.blocks[join].params.len, 0 as usize, "no value crosses the join")
}

test "a guard gets its own block and falls through to the next arm" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { x if x > 5 => 1, _ => 2 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    assert_eq(block_count_starting(f, "m_body"), 1 as usize,
        "the guarded arm splits test from body")

    // The guard block branches to the arm body on success and to the next arm's test on failure -
    // never straight to the join.
    let arm = block_starting(f, "m_arm")
    assert_true(ends_in_br_if(f, arm), "the guard is a conditional branch")
}

// `Or` and `Range` tests are side-effect free, so they combine into one operand with bitwise ops
// instead of branching - the arm still gets a single `br_if`, and the alternatives/bounds share the
// arm's test block.
test "an or-pattern tests every alternative and combines them with ior" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { 1 | 2 => 10, _ => 20 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    assert_eq(compare_count(f), 2 as usize, "one compare per alternative; the wildcard needs none")
    assert_true(has_ior_in(f, 0), "the alternatives' tests are or-ed, not branched between")
    assert_eq(block_count_starting(f, "m_arm"), 2 as usize, "the or-pattern is still one arm")
}

test "a range pattern tests both bounds and combines them with iand" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { 1..5 => 10, _ => 20 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    assert_eq(compare_count(f), 2 as usize, "one compare per bound")
    assert_true(has_iand_in(f, 0), "the bounds are and-ed into a single test")
}

test "an arm that returns keeps its return, with no branch over it" {
    let unit = analyze(from_view("fn f(a: i32) i32 { a match { 0 => { return 7 }, _ => {} } return 0 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let arm = block_starting(f, "m_arm")
    let kept = f.blocks[arm].terminator match { Ret(_) => true, _ => false }
    assert_true(kept, "the arm's own return survives")
}

test "matching an enum variant tests the discriminant" {
    let unit = analyze(from_view("type Color = enum { Red, Green, Blue }\nfn f(c: &Color) i32 { return c.* match { Red => 1, Green => 2, _ => 3 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__ref_")
    assert_true(fi < m.functions.len, "the &Color function lowered")
    let f = &m.functions[fi]
    assert_eq(compare_count(f), 2 as usize, "one discriminant test per named variant")
    // The tag is the enum's first field, so the test loads through the scrutinee pointer rather
    // than geping first.
    assert_true(load_count(f) >= 2 as usize, "each test loads the discriminant")
}

test "an unsupported pattern gates the whole match, not just its arm" {
    // Alternatives that bind are the gate: `or_test` combines subtests with `ior` and has nowhere
    // to merge two binding sets, so a tuple alternative refuses. The wildcard arm beside it is
    // supported, and the signature lowers on its own - only the pattern is out of subset, and it
    // takes the whole function with it.
    let unit = analyze(from_view("fn f(a: (i32, i32)) i32 { return a match { (0, 0) | (1, 1) => 1, _ => 2 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(m.functions.len == 0 as usize, "no half-emitted function survives the refusal")
    assert_true(was_skipped(&m, "f__tup_i32_i32"), "the whole function is recorded as skipped")

    // The same signature and the same supported arm, minus the binding alternative, lowers - the
    // refusal is the pattern's, not the shape's.
    let ok = analyze(from_view("fn f(a: (i32, i32)) i32 { return a match { (0, 0) => 1, _ => 2 } }"),
        "test.f")
    let m2 = lower_module(&ok.module, &ok.result)
    assert_true(find_fn(&m2, "f__tup_i32_i32") < m2.functions.len,
        "a tuple pattern in a tuple parameter lowers")
}

// Indexing (M5).
//
// `analyze` checks one module with no stdlib, so `Slice` and `Range` are not registered and the
// built-in element path has no type to reach it with. It is covered by the self-host run instead
// (`--check` over the stdlib, where every `xs[i]` on a slice takes it). What is testable here is
// the part that decides between call, load, and refusal.

test "a ref-form index operator is called, and its result is the address to load from" {
    let unit = analyze(from_view("type Box = struct { v: i32 }\nfn op_index_ref(b: &Box, i: usize) &i32 { return &b.v }\nfn f(b: &Box) i32 { return b[0usize] }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn_starting(&m, "f__ref")]
    assert_eq(call_count(f), 1 as usize, "the operator is called once")
    assert_eq(first_call_argc(f), 2 as usize, "receiver and index")
    assert_true(is_load_result(f, returned_local(f)), "the value is loaded, not the pointer itself")
}

test "a ref-form index is a place: assignment stores through the operator's result" {
    let unit = analyze(from_view("type Box = struct { v: i32 }\nfn op_index_ref(b: &Box, i: usize) &i32 { return &b.v }\nfn f(b: &Box) { b[0usize] = 7 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn_starting(&m, "f__ref")]
    assert_true(is_call_result(f, last_store_ptr(f)),
        "the write goes to the address the operator returned")
}

test "a value-form index operator yields its call result with nothing loaded through it" {
    let unit = analyze(from_view("type Box = struct { v: i32 }\nfn op_index(b: &Box, i: usize) i32 { return b.v }\nfn f(b: &Box) i32 { return b[0usize] }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn_starting(&m, "f__ref")]
    assert_eq(call_count(f), 1 as usize, "the operator is called once")
    assert_true(is_call_result(f, returned_local(f)), "the call result IS the value")
}

// The refusal that matters: a value-form result is a computed temporary, so writing through it
// would discard the write. Refusing the function is the only honest option until `op_set_index`
// lands.
test "a value-form index is not a place: assigning through it refuses the function" {
    let unit = analyze(from_view("type Box = struct { v: i32 }\nfn op_index(b: &Box, i: usize) i32 { return b.v }\nfn f(b: &Box) { b[0usize] = 7 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(was_skipped(&m, "f__ref"), "the assignment has no place to store to")
}

// A generic signature puts the operator itself outside the lowerable subset (no monomorphization
// yet), so it has no symbol to call. The index must refuse rather than name a function that was
// never emitted. A by-value struct receiver, by contrast, is inside the subset as of M6.
test "an index whose operator has an unlowerable signature refuses rather than guessing a symbol" {
    let unit = analyze(from_view("type Box = struct { v: i32 }\nfn op_index(b: Box, i: usize) i32 { return b.v }\nfn g(b: &Box) i32 { return b[0usize] }"),
        "test.f")
    let with_op = lower_module(&unit.module, &unit.result)
    assert_true(find_fn_starting(&with_op, "g__ref") < with_op.functions.len,
        "a by-value receiver is lowerable now")

    // A GENERIC operator specializes at the call site (M10): the index instantiates `op_index(&Box,
    // usize)` and calls its specialization.
    let unit2 = analyze(from_view("type Box = struct { v: i32 }\nfn op_index(b: &Box, i: $T) i32 { return b.v }\nfn g(b: &Box) i32 { return b[0usize] }"),
        "test.f")
    let m = lower_module(&unit2.module, &unit2.result)
    assert_true(find_fn_starting(&m, "g__ref") < m.functions.len,
        "the caller lowers against the specialization")
    assert_true(find_fn_starting(&m, "test__f__op_0index__") < m.functions.len,
        "the operator's specialization is emitted")
}

// Aggregates (M6).
//
// An aggregate crosses a call by pointer with a callee-side copy, and returns through a
// caller-allocated sret buffer. `analyze` checks one module with no stdlib, so
// `String`/`Slice`/`Option` niches are covered by the self-host run; what is testable here is the
// convention itself and the value-semantics copies.

// Stores of exactly `ty` across the whole function.
fn store_ty_count(f: &Function, ty: IrType) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match {
                Store(s) => { if s.ty == ty {
                        n = n + 1
                    } }
                _ => {}
            }
        }
    }
    return n
}

// Whether any compare in `f` tests against the integer constant `v`.
fn compares_against(f: &Function, v: i64) bool {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match {
                Compare(c) => c.rhs match { IntConst(n) => n == v, _ => false }
                _ => false
            }
            if hit {
                return true
            }
        }
    }
    return false
}

test "an aggregate parameter arrives by pointer and the callee copies it" {
    let unit = analyze(from_view("type Pt = struct { x: i32, y: i32 }\nfn get_x(p: Pt) i32 { return p.x }\nfn main() i32 { let p = Pt { x = 7, y = 1 } return get_x(p) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let ci = find_fn_starting(&m, "get_0x__")
    assert_true(ci < m.functions.len, "the by-value struct signature is lowerable now")
    let callee = &m.functions[ci]
    assert_eq(callee.params.len, 1 as usize, "one pointer parameter carries the struct")
    assert_eq(memcpy_count(callee), 1 as usize, "the callee copies the value into its own slot")

    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "the caller lowers")
    assert_eq(call_count(&m.functions[mi]), 1 as usize, "one call emitted")
    // The argument is the value's address; no caller-side copy, and the literal-initialized let
    // elides its copy too.
    assert_eq(memcpy_count(&m.functions[mi]), 0 as usize, "no caller-side copy")
}

test "an aggregate return travels through a trailing sret parameter" {
    let unit = analyze(from_view("type Pt = struct { x: i32, y: i32 }\nfn make(x: i32) Pt { return Pt { x = x, y = 0 } }\nfn main() i32 { let p = make(3) return p.x }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let ci = find_fn_starting(&m, "make__i32")
    assert_true(ci < m.functions.len, "the aggregate-returning signature is lowerable now")
    let callee = &m.functions[ci]
    assert_eq(callee.params.len, 2 as usize, "the declared param plus the sret pointer")
    assert_true(callee.return_ty.is_none(),
        "FIR return slot is empty - the buffer carries the value")
    assert_eq(memcpy_count(callee), 1 as usize, "the return copies into the sret buffer")

    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "the caller lowers")
    // The call is void at the FIR level; its result is the temp's address, and the let takes the
    // fresh buffer over without another copy.
    assert_eq(memcpy_count(&m.functions[mi]), 0 as usize, "the sret temp is bound, not re-copied")
}

test "binding an existing aggregate copies it - mutating the copy leaves the source alone" {
    let unit = analyze(from_view("type Pt = struct { x: i32, y: i32 }\nfn f(p: Pt) i32 { let q = p q.x = 9 return p.x }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn_starting(&m, "f__")]
    // One copy spills the parameter, one copies it into `q` (value semantics): `q.x = 9` must not
    // write through into `p`.
    assert_eq(memcpy_count(f), 2 as usize, "param spill plus the let's own copy")
}

test "a call omitting a defaulted argument materializes the default (M11)" {
    let unit = analyze(from_view("fn add(a: i32, b: i32 = 2) i32 { return a + b }\nfn main() i32 { return add(1) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(find_fn_starting(&m, "add__") < m.functions.len, "the callee itself lowers")
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "the short call lowers - the default is appended")
    assert_eq(call_count(&m.functions[mi]), 1 as usize, "one call emitted at full arity")

    let unit2 = analyze(from_view("fn add(a: i32, b: i32 = 2) i32 { return a + b }\nfn main() i32 { return add(1, 5) }"),
        "test.f")
    let m2 = lower_module(&unit2.module, &unit2.result)
    assert_true(find_fn(&m2, "main") < m2.functions.len, "the full-arity call lowers")
}

test "a UFCS call omitting a defaulted argument materializes the default" {
    // The receiver is prepended to the argument list; the omitted-count bookkeeping must account
    // for it (`recv_extra` in commit_pick).
    let unit = analyze(from_view("type Ctr = struct { n: i32 }\nfn bump(self: &Ctr, by: i32 = 3) i32 { return self.n + by }\nfn main() i32 { let c = Ctr { n = 1 } return c.bump() }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "the receiver-only call lowers at full arity")
    assert_eq(call_count(&m.functions[mi]), 1 as usize, "one call emitted")
}

test "an omitted `null` default on a tagged Option parameter lowers" {
    // The `&Allocator? = null` shape - the dominant default in the self-host sources: null at
    // Option(&T) is the niche retype, and at a tagged Option a zeroed buffer. Needs the REAL
    // well-known Option (see the niche tests above), so the module is labelled core.option.
    let unit = analyze(from_view("pub type Option = enum(T) { None, Some(T) }\nfn pick(v: i32, cap: usize? = null) i32 { return v }\nfn main() i32 { return pick(4) }"),
        "core.option")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "the short call lowers with a zeroed Option argument")
}

test "a specialized generic call omitting a defaulted argument lowers" {
    // The generic winner becomes an RtSpecialized target; the default recorded at pick time must
    // still be appended against the spec's full-arity signature.
    let unit = analyze(from_view("fn wrap(v: $T, extra: i32 = 7) i32 { return extra }\nfn main() i32 { return wrap(true) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "the short generic call lowers via its specialization")
    assert_eq(call_count(&m.functions[mi]), 1 as usize, "one call emitted")
}

test "a scalar module const reads through its global, initialized before main" {
    let unit = analyze(from_view("const K: i32 = 7\nfn main() i32 { return K }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "the const-reading main lowers")
    assert_true(find_fn(&m, "__finit_test__f__K") < m.functions.len, "the init function emits")
    assert_eq(m.globals.len, 1 as usize, "one global backs the const")
    // The init call is wired before any user instruction.
    let first_is_init = m.functions[mi].blocks[0].instrs[0] match {
        Call(c) => c.callee == "__finit_test__f__K"
        _ => false
    }
    assert_true(first_is_init, "main's first instruction initializes the const")
}

test "an aggregate const supports member reads and address-of" {
    let unit = analyze(from_view("type Pt = struct { x: i32, y: i32 }\nconst P = Pt { x = 3, y = 4 }\nfn main() i32 { let a = &P let b = P.x return b }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(find_fn(&m, "main") < m.functions.len,
        "member read + address-of on a const global lower")
    assert_true(find_fn(&m, "__finit_test__f__P") < m.functions.len, "the struct initializer emits")
}

test "a const vtable of function pointers lowers and dispatches" {
    let unit = analyze(from_view("type V = struct { f: fn(i32) i32 }\nfn double(x: i32) i32 { return x + x }\nconst T = V { f = double }\nfn main() i32 { let g = T.f return g(2) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(find_fn(&m, "main") < m.functions.len,
        "reading a fn field from a const global lowers")
    assert_true(find_fn(&m, "__finit_test__f__T") < m.functions.len,
        "the vtable init emits with a FuncRef store")
}

test "a const whose initializer cannot lower has no global, and its readers refuse" {
    // A binding or-pattern is out of subset (see the match gate above), so the initializer refuses
    // - the const gets no global, and its reader must refuse too, never read zeros.
    let unit = analyze(from_view("const B2: i32 = (0, 0) match { (0, 0) | (1, 1) => 1, _ => 2 }\nfn main() i32 { let x = B2 return 0 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(find_fn(&m, "__finit_test__f__B2") >= m.functions.len,
        "no init function for the unlowerable const")
    assert_eq(m.globals.len, 0 as usize, "and no global to read zeros out of")
    assert_true(was_skipped(&m, "main"), "reading an unavailable const refuses the reader")
}

test "integer casts widen and narrow through convert instructions (M11)" {
    let unit = analyze(from_view("fn f(x: i32) i64 { return x as i64 }\nfn g(x: u64) u8 { return x as u8 }\nfn h(x: u32) u64 { return x as u64 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__i32")
    assert_true(fi < m.functions.len, "the widening cast lowers")
    assert_eq(convert_count(&m.functions[fi]), 1 as usize, "one convert for i32 -> i64")
    let gi = find_fn_starting(&m, "g__u64")
    assert_true(gi < m.functions.len, "the narrowing cast lowers")
    let hi = find_fn_starting(&m, "h__u32")
    assert_true(hi < m.functions.len, "the unsigned widening cast lowers")
}

test "int/float and ptr/int casts lower; same-width sign casts are no-ops" {
    let unit = analyze(from_view("fn f(x: i32) f64 { return x as f64 }\nfn g(x: f64) i32 { return x as i32 }\nfn p(x: usize) &u8 { return x as &u8 }\nfn q(x: &u8) usize { return x as usize }\nfn s(x: u32) i32 { return x as i32 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(find_fn_starting(&m, "f__i32") < m.functions.len, "int -> float lowers")
    assert_true(find_fn_starting(&m, "g__f64") < m.functions.len, "float -> int lowers")
    assert_true(find_fn_starting(&m, "p__usize") < m.functions.len, "int -> ptr lowers")
    assert_true(find_fn_starting(&m, "q__ref_u8") < m.functions.len, "ptr -> int lowers")
    let si = find_fn_starting(&m, "s__u32")
    assert_true(si < m.functions.len, "same-width sign cast lowers")
    assert_eq(convert_count(&m.functions[si]), 0 as usize, "same width needs no instruction")
}

test "a tagged enum casts to and from an integer through its discriminant" {
    let unit = analyze(from_view("type E = enum { A, B, C }\nfn f(e: E) i32 { return e as i32 }\nfn g(x: i32) E { return x as E }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "enum -> int lowers via a tag load")
    let gi = find_fn_starting(&m, "g__i32")
    assert_true(gi < m.functions.len, "int -> enum lowers via a zeroed slot + tag store")
    assert_true(memset_count(&m.functions[gi]) == 1 as usize,
        "the slot zero-fills before the tag store")
}

test "a cast to bool refuses - truncation is not C's != 0 semantics" {
    let unit = analyze(from_view("fn f(x: i32) bool { return x as bool }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(was_skipped(&m, "f__"), "`as bool` needs a comparison, not a trunc")
}

test "a char literal lowers to its codepoint, not a placeholder zero" {
    let unit = analyze(from_view("fn f(c: char) bool { return c == 'A' }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn_starting(&m, "f__char")]
    assert_true(compares_against(f, 65), "the comparison tests against 65, not 0")
}

test "String == dispatches to op_eq, and != negates it" {
    let unit = analyze(from_view("pub type String = struct { ptr: &u8, len: usize }\npub fn op_eq(a: String, b: String) bool { return a.len == b.len }\nfn f(a: String, b: String) bool { return a == b }\nfn g(a: String, b: String) bool { return a != b }"),
        "core.string")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "== over Strings lowers via op_eq")
    assert_eq(call_count(&m.functions[fi]), 1 as usize, "one dispatch call")
    let gi = find_fn_starting(&m, "g__")
    assert_true(gi < m.functions.len, "!= lowers as negated op_eq")
    assert_eq(call_count(&m.functions[gi]), 1 as usize, "same dispatch, plus a negation")
}

test "a string match arm calls op_eq against the literal" {
    let unit = analyze(from_view("pub type String = struct { ptr: &u8, len: usize }\npub fn op_eq(a: String, b: String) bool { return a.len == b.len }\nfn f(s: String) i32 { return s match { \"build\" => 1, \"fmt\" => 2, else => 0 } }"),
        "core.string")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "string patterns lower via op_eq dispatch")
    assert_true(call_count(&m.functions[fi]) >= 2 as usize, "one call per string arm")
}

test "== and != on a payload-less enum compare tags with no dispatch" {
    let unit = analyze(from_view("type Color = enum { Red, Green, Blue }\nfn f(a: Color, b: Color) bool { return a == b }\nfn g(a: Color) bool { return a != Color.Red }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "enum == lowers as a tag compare")
    assert_eq(call_count(&m.functions[fi]), 0 as usize, "no call - builtin tag compare")
    assert_true(find_fn_starting(&m, "g__") < m.functions.len,
        "enum != against a variant value lowers")
}

test "an ordering comparison derives from op_cmp through Ord's tags" {
    let unit = analyze(from_view("pub type Ord = enum { Less, Equal, Greater }\npub type Money = struct { cents: i64 }\npub fn op_cmp(a: Money, b: Money) Ord { return Less }\nfn f(a: Money, b: Money) bool { return a < b }"),
        "core.cmp")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "< over a user type lowers via op_cmp")
    assert_eq(call_count(&m.functions[fi]), 1 as usize, "one op_cmp call, then a tag test")
}

test "a binary operator over aggregates refuses - its operator fn is not recorded" {
    let unit = analyze(from_view("type Pt = struct { x: i32 }\nfn op_eq(a: &Pt, b: &Pt) bool { return a.x == b.x }\nfn f(a: Pt, b: Pt) bool { return a == b }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(was_skipped(&m, "f__"),
        "emitting FIR arithmetic over addresses would be silently wrong")
}

test "an enum parameter passes by value and its payload binds in a match" {
    let unit = analyze(from_view("type E = enum { A, B(i32) }\nfn f(e: E) i32 { return e match { B(v) => v, A => 0 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "a by-value enum signature is lowerable now")
    let f = &m.functions[fi]
    assert_eq(f.params.len, 1 as usize, "one pointer parameter carries the enum")
    assert_true(block_count_starting(f, "m_arm") == 2 as usize, "both arms lowered")
}

test "a generic field reads at its substituted width" {
    // `w.p.a` walks into a `Pair(i64)` instantiation: the raw field type is the type parameter, and
    // loading at its placeholder width would read 4 of the 8 bytes. The load must be i64-wide.
    let unit = analyze(from_view("type Pair = struct(T) { a: T, b: T }\ntype W = struct { p: Pair(i64) }\nfn f(w: W) i64 { return w.p.a }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "a concrete instantiation of a generic struct lowers")
    let f = &m.functions[fi]
    assert_true(is_load_result(f, returned_local(f)), "the field value is loaded")
    let loads_i64 = false
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match {
                Load(l) => { if l.ty == IrType.I64 {
                        loads_i64 = true
                    } }
                _ => {}
            }
        }
    }
    assert_true(loads_i64, "the load takes the substituted 8-byte width")
}

test "a generic struct literal named without its arguments is a checker error, not lowered" {
    // `Pair { ... }` with no explicit arguments is E2019 (the reference checker rejects the same
    // shape): an under-instantiated nominal has no layout, so it must never reach lowering. The
    // literal types as `Error`, which also refuses the function if a caller lowers anyway.
    let unit = analyze(from_view("type Pair = struct(T) { a: T, b: T }\nfn main() i64 { let p = Pair { a = 1i64, b = 2i64 } return p.a }"),
        "test.f")
    assert_true(unit.error_count() > 0 as usize, "the checker rejects the literal")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(was_skipped(&m, "main"), "the Error-typed literal refuses the function")
}

// M7: enum variant construction

// How many stores in `f` write the constant `v`.
fn store_const_count(f: &Function, v: i64) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match {
                Store(s) => {
                    s.value match {
                        IntConst(c) => { if c == v {
                                n = n + 1
                            } }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
    }
    return n
}

fn memset_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match {
                Memset(_) => n = n + 1
                _ => {}
            }
        }
    }
    return n
}

fn gep_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match {
                Gep(_) => n = n + 1
                _ => {}
            }
        }
    }
    return n
}

test "constructing a payload variant stores the tag, then the payload past it" {
    let unit = analyze(from_view("type E = enum { A, B(i32) }\nfn f(x: i32) E { return B(x) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "payload construction lowers")
    let f = &m.functions[fi]
    // Tag 1 for B, stored at the slot base; the payload store goes through a gep to the layout's
    // payload offset.
    assert_eq(store_const_count(f, 1), 1 as usize, "the discriminant store writes B's index")
    assert_true(gep_count(f) >= 1 as usize, "the payload is addressed past the tag")
}

test "a bare payload-less variant builds a zeroed slot with its tag" {
    let unit = analyze(from_view("type Color = enum { Red, Green, Blue }\nfn f() Color { return Green }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn(&m, "f")
    assert_true(fi < m.functions.len, "bare variant construction lowers")
    let f = &m.functions[fi]
    assert_true(memset_count(f) >= 1 as usize, "the slot is zero-filled first")
    assert_eq(store_const_count(f, 1), 1 as usize, "Green's tag is stored over the zeros")
}

test "a qualified variant constructs - the receiver is a type, not a value" {
    let unit = analyze(from_view("type Color = enum { Red, Green, Blue }\nfn f() Color { return Color.Blue }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn(&m, "f")
    assert_true(fi < m.functions.len, "Color.Blue lowers as construction, not member access")
    assert_eq(store_const_count(&m.functions[fi], 2), 1 as usize, "Blue's tag is stored")
}

test "a generic variant payload stores at its substituted width" {
    // `S(9)` into `Opt(i64)`: the raw payload type is the type parameter, and storing at its
    // placeholder width would write 4 of the 8 bytes.
    let unit = analyze(from_view("type Opt = enum(T) { N, S(T) }\nfn f(x: i64) Opt(i64) { return S(x) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "generic instantiation construction lowers")
    let f = &m.functions[fi]
    assert_true(store_ty_count(f, IrType.I64) >= 1 as usize, "the payload store is 8 bytes wide")
}

test "an aggregate payload copies its bytes into the slot" {
    let unit = analyze(from_view("type Pt = struct { x: i64, y: i64 }\ntype E = enum { N, P(Pt) }\nfn f(p: Pt) E { return P(p) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "aggregate payload construction lowers")
    // Param copy, payload copy, sret copy - at least the payload's own memcpy must be there.
    assert_true(memcpy_count(&m.functions[fi]) >= 2 as usize, "the payload travels by memcpy")
}

// The niche tests need the REAL well-known Option: `is_option_niche` matches on the
// `core.option.Option` FQN, so each test module defines the enum itself and is labelled
// `core.option`, like the checker's own Option tests.
test "niche Some is a retype: the payload pointer IS the value" {
    let unit = analyze(from_view("pub type Option = enum(T) { None, Some(T) }\nfn f(x: &i32) &i32? { return Some(x) }"),
        "core.option")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "niche Some lowers")
    let f = &m.functions[fi]
    // No enum slot is built: no memset, no gep - the loaded parameter is returned as-is.
    assert_eq(memset_count(f), 0 as usize, "no zeroed buffer for the niche form")
    assert_eq(gep_count(f), 0 as usize, "no payload addressing for the niche form")
}

test "niche None is the null pointer" {
    let unit = analyze(from_view("pub type Option = enum(T) { None, Some(T) }\nfn f() &i32? { return None }"),
        "core.option")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn(&m, "f")
    assert_true(fi < m.functions.len, "niche None lowers")
    let f = &m.functions[fi]
    let ret_null = f.blocks[0].terminator match {
        Ret(r) => r match {
            Some(v) => v match { NullPtr => true, _ => false }
            None => false
        }
        _ => false
    }
    assert_true(ret_null, "None of Option(&T) returns the null pointer directly")
}

test "a multi-payload variant constructs and its pattern binds both payloads (M11)" {
    let unit = analyze(from_view("type P = enum { A, B(i32, i64) }\nfn f(x: i32) P { return B(x, 9i64) }\nfn g(p: P) i64 { return p match { B(a, b) => (a as i64) + b, A => 0 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(find_fn_starting(&m, "f__") < m.functions.len,
        "construction stores tag + both payloads")
    assert_true(find_fn_starting(&m, "g__") < m.functions.len,
        "the pattern binds each payload at its offset")
}

test "a constructed variant round-trips through a match in the same function" {
    let unit = analyze(from_view("type E = enum { A, B(i32) }\nfn f(x: i32) i32 { return B(x) match { B(v) => v, A => 0 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "construct-then-match lowers end to end")
}

test "an anonymous literal follows its coerced nominal type" {
    // `.{ ... }` types as a fresh var the nominal coercion resolves; the zonked node type is what
    // lowering reads, so the literal must build into a correctly-sized slot with per-field stores
    // like a named one.
    let unit = analyze(from_view("type Pt = struct { x: i32, y: i32 }\nfn f() Pt { return .{ x = 1, y = 2 } }\nfn g() i32 { let p: Pt = .{ x = 3, y = 4 } return p.y }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn(&m, "f")
    assert_true(fi < m.functions.len, "an anonymous literal in return position lowers")
    assert_eq(store_const_count(&m.functions[fi], 2), 1 as usize, "both fields store their values")
    let gi = find_fn(&m, "g")
    assert_true(gi < m.functions.len, "an annotated let binds an anonymous literal")
    assert_eq(store_const_count(&m.functions[gi], 4), 1 as usize,
        "the second field stores through its offset")
}

// M8: `??` and `?`.

test "coalesce unwraps the payload or falls through to the right side" {
    let unit = analyze(from_view("pub type Option = enum(T) { None, Some(T) }\nfn f(o: i32?, d: i32) i32 { return o ?? d }"),
        "core.option")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "the unwrap form lowers")
    let f = &m.functions[fi]
    assert_true(compare_count(f) >= 1 as usize, "the tag is tested")
    assert_true(gep_count(f) >= 1 as usize, "the payload is addressed past the tag")
    assert_eq(block_count_starting(f, "co_join"), 1 as usize, "both paths meet at one join")
}

test "coalesce chains keep the whole option" {
    let unit = analyze(from_view("pub type Option = enum(T) { None, Some(T) }\nfn g(a: i32?, b: i32?) i32? { return a ?? b }"),
        "core.option")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "g__")
    assert_true(fi < m.functions.len, "the chain form lowers")
    // The kept value is the option's own address - no payload gep on the taken path (parameter
    // spills still gep nothing).
    assert_eq(gep_count(&m.functions[fi]), 0 as usize,
        "no payload addressing when the option itself is the result")
}

test "coalesce over the niche form tests the pointer against null" {
    let unit = analyze(from_view("pub type Option = enum(T) { None, Some(T) }\nfn h(p: &i32?, q: &i32) &i32 { return p ?? q }"),
        "core.option")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "h__")
    assert_true(fi < m.functions.len, "the niche form lowers")
    let f = &m.functions[fi]
    assert_eq(gep_count(f), 0 as usize, "the pointer IS the payload - nothing to address")
    assert_eq(memset_count(f), 0 as usize, "and no tagged buffer is built")
}

test "postfix ? on a monomorphic op_try lowers the call, the branch, and the early return" {
    let unit = analyze(from_view("pub type TryResult = enum(T, R) { Continue(T), Return(R) }\ntype Res = enum { Bad, Good(i32) }\nfn op_try(self: Res) TryResult(i32, Res) { return self match { Good(v) => TryResult.Continue(v), Bad => TryResult.Return(Bad) } }\nfn f(r: Res) Res { let v = r? return Good(v + 1) }"),
        "core.try")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "construct, op_try, ? and re-construct all lower end to end")
    let f = &m.functions[fi]
    assert_true(first_callee(f).len > 0 as usize, "op_try is called, not inlined")
    // The early-return block ends in its own ret (through the sret copy).
    let rb = block_starting(f, "try_ret")
    assert_true(rb < f.blocks.len, "the return arm has its block")
    let ret_terminated = f.blocks[rb].terminator match { Ret(_) => true, _ => false }
    assert_true(ret_terminated, "the Return arm early-returns")
}

test "postfix ? through a generic op_try lowers via its specialization" {
    let unit = analyze(from_view("pub type TryResult = enum(T, R) { Continue(T), Return(R) }\ntype Box = enum(T) { Empty, Full(T) }\nfn op_try(self: Box($T)) TryResult(T, Box($U)) { return self match { Full(v) => TryResult.Continue(v), Empty => TryResult.Return(Empty) } }\nfn f(b: Box(i32)) Box(i32) { let v = b? return Full(v) }"),
        "core.try")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "the ? caller lowers against the op_try specialization")
    assert_true(find_fn_starting(&m, "core__try__op_0try__") < m.functions.len,
        "the op_try specialization is emitted")
}

// M9: the data segment - string and float literals.

// How many stores in `f` write a global's address.
fn store_global_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match {
                Store(s) => {
                    s.value match {
                        GlobalRef(_) => { n = n + 1 }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
    }
    return n
}

// The float constant `f` returns directly, or null.
fn ret_float_const(f: &Function) f64? {
    for b in 0..f.blocks.len {
        let hit: f64? = f.blocks[b].terminator match {
            Ret(r) => r match {
                Some(v) => v match { FloatConst(x) => Some(x), _ => null }
                None => null
            }
            _ => null
        }
        if hit.is_some() {
            return hit
        }
    }
    return null
}

test "a string literal builds a {ptr,len} view over a data-segment global" {
    let unit = analyze(from_view("pub type String = struct { ptr: &u8, len: usize }\nfn f() String { return \"hi\" }"),
        "core.string")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn(&m, "f")
    assert_true(fi < m.functions.len, "a function returning a string literal lowers")
    assert_eq(m.globals.len, 1 as usize, "one global holds the bytes")
    assert_true(m.globals[0].size == 3u64, "two content bytes plus the null terminator")
    let bytes = m.globals[0].init_bytes.unwrap()
    assert_true(bytes[0] == 'h', "the decoded content is in the data segment")
    assert_true(bytes[2] == 0, "null-terminated for String's C-FFI contract")
    let f = &m.functions[fi]
    assert_eq(store_global_count(f), 1 as usize, "the ptr field stores the global's address")
    assert_eq(store_const_count(f, 2), 1 as usize, "the len field stores the decoded length")
}

test "identical string literals share one global; distinct ones do not" {
    let unit = analyze(from_view("pub type String = struct { ptr: &u8, len: usize }\nfn f() String { return \"hi\" }\nfn g() String { return \"hi\" }\nfn h() String { return \"yo\" }"),
        "core.string")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.globals.len, 2 as usize, "hi interns once across functions; yo gets its own global")
}

test "string escapes decode before reaching the data segment" {
    let unit = analyze(from_view("pub type String = struct { ptr: &u8, len: usize }\nfn f() String { return \"a\\nb\" }"),
        "core.string")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.globals.len, 1 as usize, "one global")
    assert_true(m.globals[0].size == 4u64, "three decoded bytes plus the terminator")
    let bytes = m.globals[0].init_bytes.unwrap()
    assert_true(bytes[1] == 10, "the escape became the raw newline byte")
    let f = &m.functions[find_fn(&m, "f")]
    assert_eq(store_const_count(f, 3), 1 as usize, "len counts decoded bytes, not source bytes")
}

test "a float literal lowers to its parsed constant" {
    let unit = analyze(from_view("fn f() f64 { return 1.5 }\nfn g() f64 { return 3.5e2 }\nfn h() f64 { return 2.5e-2 }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let rf = ret_float_const(&m.functions[find_fn(&m, "f")])
    assert_true(rf.is_some() and rf.unwrap() == 1.5, "1.5 parses exactly")
    let rg = ret_float_const(&m.functions[find_fn(&m, "g")])
    assert_true(rg.is_some() and rg.unwrap() == 350.0, "the exponent scales the mantissa")
    let rh = ret_float_const(&m.functions[find_fn(&m, "h")])
    assert_true(rh.is_some() and rh.unwrap() == 0.025, "a negative exponent divides once")
}

test "a float literal whose type never resolves is a checker error" {
    // `x` is never constrained. Pre-M10 lowering refused the function; now the checker itself
    // reports E2001 (as the reference does), so an unresolved literal never reaches lowering at
    // all.
    let unit = analyze(from_view("fn f() i32 { let x = 1.5 return 0 }"), "test.f")
    assert_true(error_count(&unit) > 0, "the unpinned literal is E2001 at check time")
}

test "a float literal pattern compares with the scrutinee" {
    let unit = analyze(from_view("fn f(x: f64) i32 { return x match { 1.5 => 1, _ => 0 } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "a float literal pattern lowers")
    assert_true(compare_count(&m.functions[fi]) >= 1 as usize, "the arm tests the scrutinee")
}

// M9: defer.

// Position of the first Store writing constant `v` across all blocks, counting instructions in
// block order; or a large sentinel.
fn store_const_pos(f: &Function, v: i64) usize {
    let pos: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match {
                Store(s) => s.value match {
                    IntConst(n) => n == v
                    _ => false
                }
                _ => false
            }
            if hit {
                return pos
            }
            pos = pos + 1
        }
    }
    return pos + 1000000
}

// Position of the Load producing SSA id `id`, same numbering.
fn load_result_pos(f: &Function, id: u32) usize {
    let pos: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match {
                Load(l) => l.result == id
                _ => false
            }
            if hit {
                return pos
            }
            pos = pos + 1
        }
    }
    return pos + 1000000
}

fn call_count_in(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match {
                Call(_) => { n = n + 1 }
                _ => {}
            }
        }
    }
    return n
}

test "a defer fires on return, after the return value is read" {
    let unit = analyze(from_view("fn f(p: &i32) i32 { defer p.* = 2 return p.* }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "a function with defer lowers")
    let f = &m.functions[fi]
    assert_eq(store_const_count(f, 2), 1 as usize, "the deferred store is emitted once")
    // Spec 4.1: `return expr` evaluates the expression first, then defers.
    let ret_load = load_result_pos(f, returned_local(f))
    assert_true(ret_load < store_const_pos(f, 2), "the returned load precedes the deferred store")
}

test "sibling defers fire in LIFO order at scope exit" {
    let unit = analyze(from_view("fn f(p: &i32) { defer p.* = 1 defer p.* = 2 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn_starting(&m, "f__")]
    assert_true(store_const_pos(f, 2) < store_const_pos(f, 1), "the later defer fires first")
}

test "a defer in an inner block fires at that block's exit, not the function's" {
    let unit = analyze(from_view("fn f(p: &i32) { { defer p.* = 1 } p.* = 3 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn_starting(&m, "f__")]
    assert_true(store_const_pos(f, 1) < store_const_pos(f, 3),
        "the inner scope's defer fires before later statements")
}

test "break fires the defers of the scopes it escapes" {
    let unit = analyze(from_view("fn f(p: &i32, c: bool) { while c { defer p.* = 1 break } }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "defer + break lowers")
    assert_eq(store_const_count(&m.functions[fi], 1), 1 as usize,
        "the loop-body defer fires exactly once on the break edge")
}

test "the ? early return fires active defers on both paths" {
    let unit = analyze(from_view("pub type TryResult = enum(T, R) { Continue(T), Return(R) }\ntype Res = enum { Bad, Good(i32) }\nfn op_try(self: Res) TryResult(i32, Res) { return self match { Good(v) => TryResult.Continue(v), Bad => TryResult.Return(Bad) } }\nfn f(r: Res, p: &i32) Res { defer p.* = 7 let v = r? return Good(v + 1) }"),
        "core.try")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__")
    assert_true(fi < m.functions.len, "defer + ? lowers")
    assert_eq(store_const_count(&m.functions[fi], 7), 2 as usize,
        "the defer fires on the early-return path and the normal path")
}

test "an escape from inside a deferred expression refuses" {
    // `return` inside a defer would re-enter the flush emitting it - the reference rejects the `?`
    // flavor as E2091; lowering refuses both rather than loop or emit a wrong schedule.
    let unit = analyze(from_view("fn f() i32 { defer { return 1 } return 0 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(was_skipped(&m, "f"), "return-inside-defer refuses the function")
}

// M9: interpolation lowers through the checker-recorded desugar.

test "an interpolated string lowers through its recorded desugar" {
    let srcs: List(OwnedString) = list(4)
    srcs.push(from_view("pub type Option = enum(T) { None, Some(T) }"))
    srcs.push(from_view("pub type String = struct { ptr: &u8, len: usize }"))
    srcs.push(from_view("import core.string\nimport core.option\npub type SB = struct { n: usize }\npub fn string_builder(capacity: usize, allocator: &SB? = null) SB { return SB { n = capacity } }\npub fn append(sb: &SB, text: String) { sb.n = sb.n + text.len }\npub fn append(sb: &SB, v: i64) { sb.n = sb.n + 1 }\npub fn to_string(sb: &SB) String { return \"done\" }\npub fn deinit(sb: &SB) {}"))
    srcs.push(from_view("import core.string\nimport builder\nfn f(x: i64) String { return $\"v={x}!\" }"))
    let fqns: List(String) = list(4)
    fqns.push("core.option")
    fqns.push("core.string")
    fqns.push("builder")
    fqns.push("app")
    let unit = analyze_source_set(srcs, &fqns)
    assert_eq(project_error_count(&unit), 0 as usize, "the desugar checks clean")

    let m = lower_program(&unit.modules, &unit.fqns, &unit.result, host_ctx())
    assert_true(!was_skipped(&m, "app__f__"), "the interpolating function is not refused")
    let fi = find_fn_starting(&m, "app__f__")
    assert_true(fi < m.functions.len, "the interpolating function is emitted")
    // ctor + append("v=") + append(x) + append("!") + to_string + the deferred deinit: the whole
    // desugar is replayed.
    assert_eq(call_count_in(&m.functions[fi]), 6 as usize,
        "all desugared calls emit, deinit included")
    // "v=", "!", and to_string's own "done" intern like any literal.
    assert_eq(m.globals.len, 3 as usize, "segment literals land in the data segment")
}

// M10: generic specialization.

test "a generic call lowers against a per-signature specialization" {
    let unit = analyze(from_view("fn id(x: $T) T { return x }\nfn main() i32 { let a = id(1i32) let b = id(2i32) let w = id(9i64) return a + b }"),
        "test.f")
    // Three call sites, two concrete signatures.
    assert_eq(unit.result.specializations.len(), 2 as usize, "i32 twice dedups; i64 adds one")
    let m = lower_module(&unit.module, &unit.result)
    let i32_spec = find_fn(&m, "test__f__id__i32__ret_i32")
    let i64_spec = find_fn(&m, "test__f__id__i64__ret_i64")
    assert_true(i32_spec < m.functions.len, "the i32 instantiation is emitted")
    assert_true(i64_spec < m.functions.len, "the i64 instantiation is emitted")
    let mi = find_fn(&m, "main")
    assert_true(first_callee(&m.functions[mi]) == "test__f__id__i32__ret_i32",
        "the call names the specialization's symbol")
}

test "a specialization's body reads its own overlay, not another instantiation's" {
    // One template body, two instantiations: the same `x` node is i32 in one emitted function and
    // i64 in the other. The store widths prove the overlay kept them apart.
    let unit = analyze(from_view("fn pick(x: $T, y: T) T { let z = x return z }\nfn main() i64 { let a = pick(1i32, 2i32) let b = pick(3i64, 4i64) return b }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let s32 = find_fn(&m, "test__f__pick__i32__i32__ret_i32")
    let s64 = find_fn(&m, "test__f__pick__i64__i64__ret_i64")
    assert_true(s32 < m.functions.len, "the i32 instantiation is emitted")
    assert_true(s64 < m.functions.len, "the i64 instantiation is emitted")
    assert_true(store_ty_count(&m.functions[s32], IrType.I32) >= 3 as usize,
        "i32 body stores at 4 bytes")
    assert_true(store_ty_count(&m.functions[s64], IrType.I64) >= 3 as usize,
        "i64 body stores at 8 bytes")
}

test "a nested generic call lowers through both specializations" {
    let unit = analyze(from_view("fn inner(x: $T) T { return x }\nfn outer(x: $T) T { return inner(x) }\nfn main() i32 { return outer(5i32) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let oi = find_fn(&m, "test__f__outer__i32__ret_i32")
    assert_true(oi < m.functions.len, "outer's instantiation is emitted")
    assert_true(find_fn(&m, "test__f__inner__i32__ret_i32") < m.functions.len,
        "inner's instantiation is emitted")
    assert_true(first_callee(&m.functions[oi]) == "test__f__inner__i32__ret_i32",
        "outer's body calls inner's specialization")
}

test "a generic aggregate parameter lowers at its substituted layout" {
    let unit = analyze(from_view("type Pair = struct(T) { a: T\nb: T }\nfn second(p: Pair($T)) T { return p.b }\nfn main() i64 { let p = Pair(i64) { a = 1i64, b = 2i64 } return second(p) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let si = find_fn_starting(&m, "test__f__second__")
    assert_true(si < m.functions.len, "the Pair(i64) instantiation is emitted")
    // `p.b` sits at offset 8 in Pair(i64) - the load's gep proves the field type substituted before
    // layout instead of guessing 4 bytes.
    assert_true(gep_offset_count(&m.functions[si], 8) >= 1 as usize,
        "the field loads at the substituted offset")
}

// How many geps in `f` add constant byte offset `off`.
fn gep_offset_count(f: &Function, off: i64) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match {
                Gep(g) => {
                    g.offset match {
                        IntConst(v) => { if v == off {
                                n = n + 1
                            } }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
    }
    return n
}

// ─────────────────────────────────────────────────────────────────────
// Lambda / closure lowering tests (RFC-014)
// ─────────────────────────────────────────────────────────────────────

test "a non-capturing lambda emits a module-level function and a FuncRef" {
    let unit = analyze(from_view("fn apply(f: fn(i32) i32, x: i32) i32 { return f(x) }\nfn main() i32 { return apply(fn(v: i32) i32 { v + 1 }, 4) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(!was_skipped(&m, "main"), "main lowered")
    assert_true(!was_skipped(&m, "apply"), "apply lowered")
    let li = find_fn_starting(&m, "__flang_lambda_")
    assert_true(li < m.functions.len, "the lambda body was emitted as a function")
}

test "a fn-typed parameter call lowers to CallIndirect" {
    let unit = analyze(from_view("fn apply(f: fn(i32) i32, x: i32) i32 { return f(x) }\nfn main() i32 { return apply(fn(v: i32) i32 { v + 1 }, 4) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let ai = find_fn(&m, "apply__ptr_i32")
    if ai >= m.functions.len {
        ai = find_fn_starting(&m, "apply")
    }
    assert_true(ai < m.functions.len, "apply emitted")
    let saw_indirect = false
    let f = &m.functions[ai]
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match {
                CallIndirect(_) => true
                _ => false
            }
            if hit {
                saw_indirect = true
            }
        }
    }
    assert_true(saw_indirect, "the call through f is indirect")
}

test "a capturing closure through $F lowers env struct, op_call, and dispatch" {
    let unit = analyze(from_view("fn apply(f: $F, x: i32) i32 { return f(x) }\nfn main() i32 { let k = 40\n return apply(fn(v: i32) i32 { v + k }, 2) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(!was_skipped(&m, "main"), "main lowered")
    let ci = find_fn_starting(&m, "__flang_closure_call_")
    assert_true(ci < m.functions.len, "the closure op_call was emitted")
    // The instantiated apply calls the closure's op_call directly.
    let ai = find_fn_starting(&m, "test__f__apply")
    assert_true(ai < m.functions.len, "the specialization emitted")
    let callee = first_callee(&m.functions[ai])
    assert_true(callee.starts_with("__flang_closure_call_"), "dispatch is a direct call to op_call")
}

test "a named function through $F lowers via FuncRef + CallIndirect" {
    let unit = analyze(from_view("fn double_it(x: i32) i32 { return x * 2 }\nfn apply(f: $F, x: i32) i32 { return f(x) }\nfn main() i32 { return apply(double_it, 5) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(!was_skipped(&m, "main"), "main lowered")
    let ai = find_fn_starting(&m, "test__f__apply")
    assert_true(ai < m.functions.len, "specialization emitted")
}

test "two unannotated lambdas settling to one signature dedup the spec symbol" {
    // Each pick enters instantiation with a var-bearing key (`fn(?a) ?b`); both settle to `fn(i32)
    // i32`, so their final symbols collide - emission keeps the first and skips the twin.
    // (Capturing closures never collide: each literal is its own nominal.)
    let unit = analyze(from_view("fn apply(f: $F, x: i32) i32 { return f(x) }\nfn main() i32 { return apply(fn(v) { v + 1 }, 1) + apply(fn(v) { v * 2 }, 2) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(!was_skipped(&m, "main"), "main lowered")
    let seen: usize = 0
    for i in 0..m.functions.len {
        if m.functions[i].name.starts_with("test__f__apply") {
            seen = seen + 1
        }
    }
    assert_eq(seen, 1 as usize, "one apply specialization emitted")
    // Both lambda bodies still exist as separate functions.
    let bodies: usize = 0
    for i in 0..m.functions.len {
        if m.functions[i].name.starts_with("__flang_lambda_") {
            bodies = bodies + 1
        }
    }
    assert_eq(bodies, 2 as usize, "each lambda keeps its own body")
}

test "a closure stored in a generic struct field dispatches on h.f(x)" {
    let unit = analyze(from_view("type Holder = struct(F) { f: F }\nfn hold(f: $F) Holder(F) { return .{ f = f } }\nfn invoke(h: &Holder($F), x: i32) i32 { return h.f(x) }\nfn main() i32 { let b = 5\n let h = hold(fn(v: i32) i32 { v + b })\n return invoke(&h, 1) }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(!was_skipped(&m, "main"), "main lowered")
    let ii = find_fn_starting(&m, "test__f__invoke")
    assert_true(ii < m.functions.len, "invoke specialization emitted")
    let callee = first_callee(&m.functions[ii])
    assert_true(callee.starts_with("__flang_closure_call_"), "field call dispatches to op_call")
}

// The stage-2 segfault family: a UFCS receiver that only resolves through op_deref must CALL the
// hop - passing the wrapper's address as the inner type read every field at a shifted offset.

test "a UFCS receiver behind op_deref calls the hop, not the wrapper's address" {
    let unit = analyze(from_view("type Inner = struct { a: i64, b: i64 }\ntype Wrap = struct { tag: i64, inner: Inner }\nfn op_deref(w: &Wrap) &Inner { return &w.inner }\nfn get_b(i: &Inner) i64 { return i.b }\nfn f(w: &Wrap) i64 { return w.get_b() }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__ref")
    assert_true(fi < m.functions.len, "the call lowers")
    assert_eq(call_count(&m.functions[fi]), 2 as usize, "op_deref first, then the method")
}

test "a generic op_deref wrapper instantiates and the method call routes through it" {
    let unit = analyze(from_view("type Box = struct(T) { tag: i64, v: T }\nfn op_deref(b: &Box($T)) &T { return &b.v }\nfn get(x: &i64) i64 { return x.* }\nfn f(b: &Box(i64)) i64 { return b.get() }"),
        "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__ref")
    assert_true(fi < m.functions.len, "the call lowers")
    assert_eq(call_count(&m.functions[fi]), 2 as usize, "the deref hop is a real call")
    assert_true(find_fn_starting(&m, "test__f__op_0deref__") < m.functions.len,
        "the hop's specialization is emitted")
}

// The decay half of the same hunt: a let-bound array passed where a slice parameter is declared
// must get a fresh {ptr, len} view - the raw array bytes read as a slice were a wild pointer.

test "a let-bound array argument decays into a slice view at the call" {
    let srcs: List(OwnedString) = list(2)
    srcs.push(from_view("pub type Slice = struct(T) { ptr: &T, len: usize }"))
    srcs.push(from_view("fn takes(s: u8[]) i64 { return 7 }\nfn f() i64 { const buf = [0u8; 4]\n return takes(buf) }"))
    let fqns: List(String) = list(2)
    fqns.push("core.slice")
    fqns.push("app")
    let unit = analyze_source_set(srcs, &fqns)
    assert_eq(project_error_count(&unit), 0 as usize, "the decay checks clean")
    let m = lower_program(&unit.modules, &unit.fqns, &unit.result, host_ctx())
    assert_true(!was_skipped(&m, "app__f"), "the call lowers")
    let fi = find_fn_starting(&m, "app__f")
    assert_true(fi < m.functions.len, "f emitted")
    assert_true(store_const_count(&m.functions[fi], 4) >= 1 as usize,
        "the view's len field is stored")
}

test "a DBL_MAX-magnitude literal parses finite, not infinite" {
    let unit = analyze(from_view("fn f() f64 { return 1.7976931348623157e308 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let rv = ret_float_const(&m.functions[find_fn(&m, "f")])
    assert_true(rv.is_some(), "the literal lowers")
    const v = rv.unwrap()
    assert_true(v * 0.5 != v, "the parse stays finite")
}
