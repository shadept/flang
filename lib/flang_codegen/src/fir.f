// FIR - typed, SSA, block-based IR. See `docs/fir.md` for the design and canonical text format.

import std.allocator
import std.dict
import std.list
import std.set
import std.string

// ─────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────

// A by-value aggregate crossing a C call boundary. FIR models aggregates as opaque bytes everywhere
// else - a native call passes their address, and an aggregate return uses an sret slot. That breaks
// down at a FOREIGN boundary: the platform ABI classifies a struct argument by its own size and
// alignment, so the declaration has to name a real C type or the call disagrees with the C
// definition it links against.
//
// `name` is the struct the backend emits; `AggDef` below carries what it contains.
// `symbol_table.f::agg_abi_safe` is the gate on which aggregates may cross at all.
pub type AggType = struct {
    // Interned view (`lower.f` owns the storage): the emitted C struct name, the FLang FQN with
    // dots replaced by underscores.
    name: String
    size: usize
    align: usize
}

// One member of an emitted aggregate. `ty` may itself be an `Agg`, which names a nested struct -
// the recursion stops there because `AggType` carries only a name, so `IrType` stays a flat,
// freely-copyable value.
pub type AggField = struct {
    ty: IrType
    // Array length; 1 for a plain scalar member.
    count: usize
}

// The definition behind an `AggType`: what the backend writes out. Members are FAITHFUL - a `f32`
// field is emitted as `float`, not as bytes - because the platform ABI classifies a struct by its
// member types. On x86-64 SysV a float member puts its eightbyte in class SSE, so a byte-blob
// stand-in would be passed in the wrong registers.
pub type AggDef = struct {
    name: String
    size: usize
    align: usize
    fields: List(AggField)
}

// Seven scalars, plus `Agg` for the one case that needs more. Aggregates (structs, enums, arrays,
// slices) are otherwise NOT FIR types - they live in memory as opaque byte buffers, addressed via
// `gep` + `load`/`store`, and the lowering pass resolves their layouts before FIR is emitted. `Agg`
// is the exception a foreign boundary forces, where the C ABI needs a named type rather than an
// address - see `AggType` above.
pub type IrType = enum {
    I8
    I16
    I32
    I64
    F32
    F64
    Ptr
    Agg(AggType)
}

// Calling convention attached to functions, foreign decls, and indirect call signatures.
pub type CallConv = enum {
    C
}

// Bytes of storage occupied by a value of this type. `Ptr` assumes a 64-bit target.
pub fn byte_size(ty: IrType) usize {
    return ty match {
        I8 => 1
        I16 => 2
        I32 => 4
        I64 => 8
        F32 => 4
        F64 => 8
        Ptr => 8
        Agg(a) => a.size
    }
}

// Natural alignment of a value of this type. Equal to `byte_size` for the primitives FIR supports;
// an aggregate carries its own.
pub fn byte_align(ty: IrType) usize {
    return ty match {
        Agg(a) => a.align
        _ => ty.byte_size()
    }
}

// Lower-case mnemonic used by the text format (`i8`, `i16`, ..., `ptr`).
pub fn name(ty: IrType) String {
    return ty match {
        I8 => "i8"
        I16 => "i16"
        I32 => "i32"
        I64 => "i64"
        F32 => "f32"
        F64 => "f64"
        Ptr => "ptr"
        Agg(a) => a.name
    }
}

// Structural equality. Compared by text form, which is unique per type: scalars have fixed
// mnemonics and an aggregate carries its mangled FQN.
pub fn op_eq(a: IrType, b: IrType) bool {
    return a.name() == b.name()
}

pub fn name(cc: CallConv) String {
    return cc match {
        C => "C"
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Values and operands
// ─────────────────────────────────────────────────────────────────────────

// SSA value identifier. Unique within a function; block parameters and instruction results share
// the namespace. Allocated from `Function.next_value_id`.

// An operand: SSA reference or untyped constant. The consuming instruction's slot determines the
// type for constants.
pub type Operand = enum {
    Local(u32)
    IntConst(i64)
    FloatConst(f64)
    NullPtr
    GlobalRef(String)
    FuncRef(String)
}

// ─────────────────────────────────────────────────────────────────────────
// Instructions
// ─────────────────────────────────────────────────────────────────────────

// Non-terminator instructions. Result types are explicit on every value-producing variant.
pub type Instr = enum {
    Binary(BinaryInstr)
    Unary(UnaryInstr)
    Compare(CompareInstr)
    Convert(ConvertInstr)
    StackSlot(StackSlotInstr)
    Load(LoadInstr)
    Store(StoreInstr)
    Gep(GepInstr)
    Memcpy(MemcpyInstr)
    Memset(MemsetInstr)
    Call(CallInstr)
    CallIndirect(CallIndirectInstr)
}

// Two-operand arithmetic / bitwise. Operands and result all share `ty`.
pub type BinaryInstr = struct {
    result: u32
    op: BinaryOp
    ty: IrType
    lhs: Operand
    rhs: Operand
}

pub type BinaryOp = enum {
    IAdd
    ISub
    IMul
    SDiv
    UDiv
    SRem
    URem
    IAnd
    IOr
    IXor
    IShl
    UShr
    SShr
    FAdd
    FSub
    FMul
    FDiv
}

// Single-operand arithmetic.
pub type UnaryInstr = struct {
    result: u32
    op: UnaryOp
    ty: IrType
    operand: Operand
}

pub type UnaryOp = enum {
    INeg
    FNeg
}

// Comparison. Result is i8 (0 or 1). Float compares are ordered: any NaN operand yields false.
pub type CompareInstr = struct {
    result: u32
    op: CompareOp
    operand_ty: IrType
    lhs: Operand
    rhs: Operand
}

pub type CompareOp = enum {
    IcmpEq
    IcmpNe
    IcmpSlt
    IcmpSle
    IcmpSgt
    IcmpSge
    IcmpUlt
    IcmpUle
    IcmpUgt
    IcmpUge
    FcmpEq
    FcmpNe
    FcmpLt
    FcmpLe
    FcmpGt
    FcmpGe
}

// Numeric conversion between `source_ty` and `result_ty`. `Bitcast` requires both to have the same
// byte size.
pub type ConvertInstr = struct {
    result: u32
    op: ConvertOp
    source_ty: IrType
    result_ty: IrType
    operand: Operand
}

pub type ConvertOp = enum {
    Trunc
    ZExt
    SExt
    FpToSi
    FpToUi
    SiToFp
    UiToFp
    FpExt
    FpTrunc
    Bitcast
    PtrToInt
    IntToPtr
}

// Stack allocation. Result points at the start of the slot; the slot lives until the function
// returns.
pub type StackSlotInstr = struct {
    result: u32
    size: u64
    align: u64
}

// Typed load. `align = 0` means natural alignment of `ty`.
pub type LoadInstr = struct {
    result: u32
    ty: IrType
    ptr: Operand
    align: u64
}

// Typed store. `align = 0` means natural alignment of `ty`.
pub type StoreInstr = struct {
    ty: IrType
    value: Operand
    ptr: Operand
    align: u64
}

// Pointer + signed byte offset. See `docs/fir.md` § Memory for
// edge-case semantics.
pub type GepInstr = struct {
    result: u32
    ptr: Operand
    offset: Operand
}

// Non-overlapping byte copy.
pub type MemcpyInstr = struct {
    dst: Operand
    src: Operand
    size: Operand
}

// Fill `size` bytes at `dst` with `byte`.
pub type MemsetInstr = struct {
    dst: Operand
    byte: Operand
    size: Operand
}

// Direct call. `result`/`result_ty` are null for void calls. When `variadic_arg_types` is
// non-empty, the last `variadic_arg_types.len` entries of `args` are the variadic portion.
pub type CallInstr = struct {
    result: u32?
    result_ty: IrType?
    callee: String
    args: List(Operand)
    variadic_arg_types: List(IrType)
}

// Indirect call through a `ptr` value. The signature is inlined since FIR doesn't carry
// function-pointer types.
pub type CallIndirectInstr = struct {
    result: u32?
    result_ty: IrType?
    fn_ptr: Operand
    param_types: List(IrType)
    args: List(Operand)
    variadic_arg_types: List(IrType)
    cc: CallConv
}

// ─────────────────────────────────────────────────────────────────────────
// Terminators
// ─────────────────────────────────────────────────────────────────────────

// Branch target. `args` count and types must match the target block's `params`.
pub type BlockTarget = struct {
    label: String
    args: List(Operand)
}

// Every block ends in one of these. There is no fall-through.
pub type Terminator = enum {
    Br(BlockTarget)
    BrIf(BrIfTerm)
    Ret(Operand?)
    Unreachable
}

pub type BrIfTerm = struct {
    cond: Operand
    then_target: BlockTarget
    else_target: BlockTarget
}

// ─────────────────────────────────────────────────────────────────────────
// Blocks and functions
// ─────────────────────────────────────────────────────────────────────────

// Typed SSA value defined as a function or block parameter.
pub type BlockParam = struct {
    id: u32
    ty: IrType
}

// Basic block. The first block of a function is the entry block; its `params` are the function's
// parameters.
pub type Block = struct {
    label: String
    params: List(BlockParam)
    instrs: List(Instr)
    terminator: Terminator
}

// Replace a block's instruction list wholesale (scoped mutability keeps the field module-private).
// Used by the const-init wiring in lower.f, which prepends calls to `main`'s entry block after it
// is built.
pub fn set_instrs(self: &Block, instrs: List(Instr)) {
    self.instrs = instrs
}

// FIR function. `params` carries the SSA-named function parameters; they're in scope across every
// block via dominance. `return_ty = null` is void return. `variadic = true` is reserved for foreign
// decls; the validator rejects it on defined functions. `next_value_id` is the monotonic counter
// builders consume for fresh SSA ids.
pub type Function = struct {
    name: String
    params: List(BlockParam)
    return_ty: IrType?
    blocks: List(Block)
    variadic: bool
    cc: CallConv
    next_value_id: u32
    // Owned backing buffers for builder-minted block labels; every `Block.label` and branch target
    // is a view into one of these.
    label_storage: List(OwnedString)
}

// ─────────────────────────────────────────────────────────────────────────
// IrModule-level declarations
// ─────────────────────────────────────────────────────────────────────────

// Named static buffer in the data segment. `init_bytes = null` is BSS (zero-filled).
pub type Global = struct {
    name: String
    size: u64
    align: u64
    init_bytes: u8[]?
}

// External symbol declaration. Typically C stdlib or a sibling `.c` file.
pub type ForeignDecl = struct {
    name: String
    return_ty: IrType?
    param_types: List(IrType)
    variadic: bool
    cc: CallConv
}

// The nullary function holding the constant-initializer calls in a test binary. Fixed rather than
// carried on the module: lowering always emits it in test mode and the generated runner always
// calls it, so there is nothing to communicate.
pub const CONST_INIT_SYM: String = "__flang_const_init"

// One `test {}` block that lowered, in the order the runner should run them. `label` is the block's
// name as written; `symbol` is the nullary void function it lowered to.
pub type TestCase = struct {
    label: OwnedString
    symbol: OwnedString
}

// Unit of compilation.
pub type IrModule = struct {
    globals: List(Global)
    foreigns: List(ForeignDecl)
    functions: List(Function)
    // TEMPORARY SCAFFOLD - symbols the front end declined to emit because their bodies used a
    // construct it cannot yet represent. Recorded rather than dropped silently: a program missing a
    // function fails loudly at link time, whereas one built from placeholder values does not fail
    // at all. Exists only while lowering covers a subset of the language; remove together with
    // `lower.f::unlowerable` once lowering is total.
    //
    // ponytail: milestone-period crutch; delete once lowering is total.
    skipped: List(String)
    // Human-readable reason per skip, in push order ("body refused" vs "calls undefined `x`"). Same
    // lifetime and removal condition as `skipped`; the verbose CLI build prints it as the frontier
    // report.
    skip_notes: List(OwnedString)
    // Distinct by-value aggregate types any foreign declaration mentions. The backend emits one C
    // struct definition per entry, before the externs that name them. Nested aggregates are
    // registered before the structs that contain them, so emitting in order is already valid C.
    aggs: List(AggDef)
    // Human-readable name per mangled function symbol (`module.path.name(&Type,u32)`), for
    // consumers that show names to people - the profiler's name table today, debug info tomorrow.
    // Keys are views into storage that outlives the module; values are owned here. Symbols without
    // an entry (`main`, foreigns, generated helpers) display as themselves.
    displays: Dict(String, OwnedString)
    // Test mode: the backend emits the test runner as the C entry point instead of wrapping a FIR
    // `main`. Tracked apart from `tests` because a run whose filters matched nothing still needs a
    // binary that starts, reports that it found no tests, and exits successfully.
    testing: bool
    // The `test {}` blocks this module lowered, in run order. Empty for an ordinary build, and also
    // for a test build whose filters selected nothing.
    tests: List(TestCase)
    // Symbol of `std.test.install_test_allocator`, when the module set had it and it lowered. The
    // runner calls it once, after the constant initializers and before the first test. Null when
    // std.test is not in the module set, in which case the run has no leak tracking.
    install_tests: OwnedString?
}

// ─────────────────────────────────────────────────────────────────────────
// Constructors
// ─────────────────────────────────────────────────────────────────────────

pub fn module(allocator: &Allocator? = null) IrModule {
    let globals: List(Global) = list(0, allocator)
    let foreigns: List(ForeignDecl) = list(0, allocator)
    let functions: List(Function) = list(0, allocator)
    let skipped: List(String) = list(0, allocator)
    let skip_notes: List(OwnedString) = list(0, allocator)
    let aggs: List(AggDef) = list(0, allocator)
    let displays: Dict(String, OwnedString) = dict(allocator)
    let tests: List(TestCase) = list(0, allocator)
    return IrModule {
        globals = globals,
        foreigns = foreigns,
        functions = functions,
        skipped = skipped,
        skip_notes = skip_notes,
        aggs = aggs,
        displays = displays,
        testing = false,
        tests = tests,
        install_tests = null,
    }
}

pub fn deinit(self: &IrModule) {
    for &t in self.tests {
        t.label.deinit()
        t.symbol.deinit()
    }
    self.tests.deinit()
    self.install_tests match {
        Some(s) => s.deinit()
        None => {}
    }
    self.aggs.deinit()
    self.functions.deinit()
    self.foreigns.deinit()
    self.globals.deinit()
    self.skip_notes.deinit()
    self.displays.deinit()
}

// Replace the display-name map wholesale (scoped mutability keeps the field module-private).
// Returns the previous map so the caller can free it.
pub fn set_displays(self: &IrModule, displays: Dict(String, OwnedString)) Dict(String,
    OwnedString) {
    let old = self.displays
    self.displays = displays
    return old
}

// Scoped mutability: lowering declares the module a test binary before recording any block.
pub fn set_testing(self: &IrModule, on: bool) {
    self.testing = on
}

// Record a lowered `test {}` block. Order is run order.
pub fn add_test(self: &IrModule, label: OwnedString, symbol: OwnedString) {
    self.tests.push(TestCase { label = label, symbol = symbol })
}

// Keep only the tests whose symbol is still defined. Lowering calls this once, after the refusal
// fixpoint: a block whose function was dropped must leave the runner's table with it.
pub fn retain_defined_tests(self: &IrModule, dropped: &Set(String)) {
    let kept: List(TestCase) = list(self.tests.len, self.tests.allocator)
    for &t in self.tests {
        if dropped.contains(t.symbol.as_view()) {
            t.label.deinit()
            t.symbol.deinit()
            continue
        }
        kept.push(t.*)
    }
    self.tests.deinit()
    self.tests = kept
}

// Scoped mutability: named once by lowering, when the symbol is known to have been emitted.
pub fn set_install_tests(self: &IrModule, symbol: OwnedString) {
    self.install_tests = Some(symbol)
}

pub fn deinit(self: &Function) {
    self.blocks.deinit()
    self.params.deinit()
    self.label_storage.deinit()
}

pub fn deinit(self: &Block) {
    self.instrs.deinit()
    self.params.deinit()
    self.terminator.deinit()
}

pub fn deinit(self: &Instr) {
    self.* match {
        Call(c) => {
            c.args.deinit()
            c.variadic_arg_types.deinit()
        }
        CallIndirect(c) => {
            c.args.deinit()
            c.param_types.deinit()
            c.variadic_arg_types.deinit()
        }
        _ => {}
    }
}

pub fn deinit(self: &Terminator) {
    self.* match {
        Br(t) => t.args.deinit()
        BrIf(b) => {
            b.then_target.args.deinit()
            b.else_target.args.deinit()
        }
        _ => {}
    }
}

pub fn deinit(self: &ForeignDecl) {
    self.param_types.deinit()
}

pub fn deinit(self: &Global) {
    // init_bytes is borrowed (caller owns); nothing to free here.
}

// ─────────────────────────────────────────────────────────────────────────
// Mutators
// ─────────────────────────────────────────────────────────────────────────

// Hand this instance's buffers to a copy the caller took: the list fields are re-pointed at fresh
// zero-cap lists, so a later `deinit` here frees nothing.
pub fn release_buffers(self: &Function, allocator: &Allocator?) {
    self.params = list(0, allocator)
    self.blocks = list(0, allocator)
    self.label_storage = list(0, allocator)
}

// Take ownership of a minted label buffer; returns the stable view the caller stores in blocks and
// branch targets.
pub fn add_label(self: &Function, owned: OwnedString) String {
    let view = owned.as_view()
    self.label_storage.push(owned)
    return view
}

// Hand out the next SSA value id and bump the counter.
pub fn fresh_value_id(self: &Function) u32 {
    const id = self.next_value_id
    self.next_value_id = id + 1
    return id
}

// Replace the block's terminator. Overwrites whatever was there - callers building a block from
// scratch start with `Unreachable` and call this once, so the discarded value owns no heap. Pair
// with `replace_terminator` (below) when the previous terminator may own `BlockTarget` args that
// need freeing.
pub fn set_terminator(self: &Block, t: Terminator) {
    self.terminator = t
}

// Replace the block's instruction list, returning the prior list so the caller can free its
// embedded storage. Used by IR transforms (e.g. the shim inliner) that rebuild blocks
// instruction-by- instruction; using direct field assignment is blocked by scoped mutability
// outside this module.
pub fn replace_instrs(self: &Block, instrs: List(Instr)) List(Instr) {
    let old = self.instrs
    self.instrs = instrs
    return old
}

// Replace the block's terminator, returning the previous one. Mirrors `replace_instrs`: lets
// external transforms swap terminators while keeping ownership of the discarded value so they can
// deinit its `BlockTarget` args.
pub fn replace_terminator(self: &Block, t: Terminator) Terminator {
    let old = self.terminator
    self.terminator = t
    return old
}

// Append a function parameter.
pub fn add_param(self: &Function, p: BlockParam) {
    self.params.push(p)
}

// Append a block and return its index.
pub fn add_block(self: &Function, b: Block) usize {
    self.blocks.push(b)
    return self.blocks.len - 1
}

pub fn add_function(self: &IrModule, f: Function) {
    self.functions.push(f)
}

pub fn add_foreign(self: &IrModule, f: ForeignDecl) {
    self.foreigns.push(f)
}

// Record an aggregate definition the backend must emit, once per name.
pub fn add_agg(self: &IrModule, a: AggDef) {
    for i in 0..self.aggs.len {
        if self.aggs[i].name == a.name {
            return
        }
    }
    self.aggs.push(a)
}

pub fn add_global(self: &IrModule, g: Global) {
    self.globals.push(g)
}
