// FIR — typed, SSA, block-based IR. See `docs/fir.md` for the design
// and canonical text format.

import std.allocator
import std.list
import std.option
import std.string

// ─────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────

// The seven FIR primitives. Aggregates (structs, enums, arrays, slices)
// are not FIR types — they live in memory as opaque byte buffers,
// addressed via `gep` + `load`/`store`. The lowering pass resolves all
// aggregate layouts before FIR is emitted.
pub type IrType = enum {
    I8
    I16
    I32
    I64
    F32
    F64
    Ptr
}

// Calling convention attached to functions, foreign decls, and indirect
// call signatures.
pub type CallConv = enum {
    C
}

// Bytes of storage occupied by a value of this type. `Ptr` assumes a
// 64-bit target.
pub fn byte_size(ty: IrType) usize {
    return ty match {
        I8 => 1,
        I16 => 2,
        I32 => 4,
        I64 => 8,
        F32 => 4,
        F64 => 8,
        Ptr => 8,
    }
}

// Natural alignment of a value of this type. Equal to `byte_size` for
// the primitives FIR supports.
pub fn byte_align(ty: IrType) usize {
    return ty.byte_size()
}

// Lower-case mnemonic used by the text format (`i8`, `i16`, ..., `ptr`).
pub fn name(ty: IrType) String {
    return ty match {
        I8 => "i8",
        I16 => "i16",
        I32 => "i32",
        I64 => "i64",
        F32 => "f32",
        F64 => "f64",
        Ptr => "ptr",
    }
}

pub fn name(cc: CallConv) String {
    return cc match {
        C => "C",
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Values and operands
// ─────────────────────────────────────────────────────────────────────────

// SSA value identifier. Unique within a function; block parameters and
// instruction results share the namespace. Allocated from
// `Function.next_value_id`.

// An operand: SSA reference or untyped constant. The consuming
// instruction's slot determines the type for constants.
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

// Non-terminator instructions. Result types are explicit on every
// value-producing variant.
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

// Comparison. Result is i8 (0 or 1). Float compares are ordered:
// any NaN operand yields false.
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

// Numeric conversion between `source_ty` and `result_ty`. `Bitcast`
// requires both to have the same byte size.
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

// Stack allocation. Result points at the start of the slot; the slot
// lives until the function returns.
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

// Direct call. `result`/`result_ty` are null for void calls. When
// `variadic_arg_types` is non-empty, the last `variadic_arg_types.len`
// entries of `args` are the variadic portion.
pub type CallInstr = struct {
    result: u32?
    result_ty: IrType?
    callee: String
    args: List(Operand)
    variadic_arg_types: List(IrType)
}

// Indirect call through a `ptr` value. The signature is inlined since
// FIR doesn't carry function-pointer types.
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

// Branch target. `args` count and types must match the target block's
// `params`.
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

// Basic block. The first block of a function is the entry block; its
// `params` are the function's parameters.
pub type Block = struct {
    label: String
    params: List(BlockParam)
    instrs: List(Instr)
    terminator: Terminator
}

// FIR function. `params` carries the SSA-named function parameters;
// they're in scope across every block via dominance. `return_ty = null`
// is void return. `variadic = true` is reserved for foreign decls; the
// validator rejects it on defined functions. `next_value_id` is the
// monotonic counter builders consume for fresh SSA ids.
pub type Function = struct {
    name: String
    params: List(BlockParam)
    return_ty: IrType?
    blocks: List(Block)
    variadic: bool
    cc: CallConv
    next_value_id: u32
}

// ─────────────────────────────────────────────────────────────────────────
// IrModule-level declarations
// ─────────────────────────────────────────────────────────────────────────

// Named static buffer in the data segment. `init_bytes = null` is BSS
// (zero-filled).
pub type Global = struct {
    name: String
    size: u64
    align: u64
    init_bytes: u8[]?
}

// External symbol declaration. Typically C stdlib or a sibling `.c`
// file.
pub type ForeignDecl = struct {
    name: String
    return_ty: IrType?
    param_types: List(IrType)
    variadic: bool
    cc: CallConv
}

// Unit of compilation.
pub type IrModule = struct {
    globals: List(Global)
    foreigns: List(ForeignDecl)
    functions: List(Function)
}

// ─────────────────────────────────────────────────────────────────────────
// Constructors
// ─────────────────────────────────────────────────────────────────────────

pub fn module(allocator: &Allocator? = null) IrModule {
    let globals: List(Global) = list(0, allocator)
    let foreigns: List(ForeignDecl) = list(0, allocator)
    let functions: List(Function) = list(0, allocator)
    return IrModule {
        globals = globals,
        foreigns = foreigns,
        functions = functions,
    }
}

pub fn deinit(self: &IrModule) {
    for i in 0..self.functions.len {
        self.functions[i].deinit()
    }
    for i in 0..self.foreigns.len {
        self.foreigns[i].deinit()
    }
    for i in 0..self.globals.len {
        self.globals[i].deinit()
    }
    self.functions.deinit()
    self.foreigns.deinit()
    self.globals.deinit()
}

pub fn deinit(self: &Function) {
    for i in 0..self.blocks.len {
        self.blocks[i].deinit()
    }
    self.blocks.deinit()
    self.params.deinit()
}

pub fn deinit(self: &Block) {
    for i in 0..self.instrs.len {
        self.instrs[i].deinit()
    }
    self.instrs.deinit()
    self.params.deinit()
    self.terminator.deinit()
}

pub fn deinit(self: &Instr) {
    self.* match {
        Call(c) => { c.args.deinit(); c.variadic_arg_types.deinit() },
        CallIndirect(c) => {
            c.args.deinit()
            c.param_types.deinit()
            c.variadic_arg_types.deinit()
        },
        _ => {},
    }
}

pub fn deinit(self: &Terminator) {
    self.* match {
        Br(t) => t.args.deinit(),
        BrIf(b) => { b.then_target.args.deinit(); b.else_target.args.deinit() },
        _ => {},
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

// Hand out the next SSA value id and bump the counter.
pub fn fresh_value_id(self: &Function) u32 {
    const id = self.next_value_id
    self.next_value_id = id + 1
    return id
}

// Replace the block's terminator. Overwrites whatever was there —
// callers building a block from scratch start with `Unreachable` and
// call this once, so the discarded value owns no heap. Pair with
// `replace_terminator` (below) when the previous terminator may own
// `BlockTarget` args that need freeing.
pub fn set_terminator(self: &Block, t: Terminator) {
    self.terminator = t
}

// Replace the block's instruction list, returning the prior list so
// the caller can free its embedded storage. Used by IR transforms
// (e.g. the shim inliner) that rebuild blocks instruction-by-
// instruction; using direct field assignment is blocked by scoped
// mutability outside this module.
pub fn replace_instrs(self: &Block, instrs: List(Instr)) List(Instr) {
    let old = self.instrs
    self.instrs = instrs
    return old
}

// Replace the block's terminator, returning the previous one. Mirrors
// `replace_instrs`: lets external transforms swap terminators while
// keeping ownership of the discarded value so they can deinit its
// `BlockTarget` args.
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

pub fn add_global(self: &IrModule, g: Global) {
    self.globals.push(g)
}
