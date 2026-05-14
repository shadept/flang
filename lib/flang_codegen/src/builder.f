// Builder API for constructing FIR programs.
//
// `function()` starts a `FunctionBuilder`. Add blocks via `.entry()` /
// `.block()`. Each returns a `BlockBuilder` that emits instructions and
// terminators. `.finish()` hands back the underlying `Function` for
// inclusion in a `Module`.
//
// Instruction emitters return `Operand` (the just-produced SSA value)
// so results chain directly into the next call. Terminators (`ret`,
// `br`, `br_if`, `unreachable`) return nothing; calling one twice on
// the same block overwrites the previous terminator.

import std.allocator
import std.list
import std.option
import std.string
import flang_codegen.fir

// ─────────────────────────────────────────────────────────────────────────
// Operand helpers
// ─────────────────────────────────────────────────────────────────────────

pub fn int(n: i64) Operand { return Operand.IntConst(n) }
pub fn float(f: f64) Operand { return Operand.FloatConst(f) }
pub fn null_ptr() Operand { return Operand.NullPtr }
pub fn global(name: String) Operand { return Operand.GlobalRef(name) }
pub fn func_ref(name: String) Operand { return Operand.FuncRef(name) }

// ─────────────────────────────────────────────────────────────────────────
// FunctionBuilder
// ─────────────────────────────────────────────────────────────────────────

pub type FunctionBuilder = struct {
    func: Function
    allocator: &Allocator
}

// Start a new function. `return_ty = null` is void return. Add params
// via `.param(ty)` before calling `.entry()`.
pub fn function(name: String, return_ty: IrType?, allocator: &Allocator? = null) FunctionBuilder {
    const alloc = allocator.or_global()
    let params: List(BlockParam) = list(0, alloc)
    let blocks: List(Block) = list(0, alloc)
    return FunctionBuilder {
        func = Function {
            name = name,
            params = params,
            return_ty = return_ty,
            blocks = blocks,
            variadic = false,
            cc = CallConv.C,
            next_value_id = 0u32,
        },
        allocator = alloc,
    }
}

// Hand out a fresh SSA value id.
pub fn fresh(self: &FunctionBuilder) u32 {
    return self.func.fresh_value_id()
}

// Declare a function parameter and return its SSA operand. Call before
// `.entry()` — order determines argument order at call sites.
pub fn param(self: &FunctionBuilder, ty: IrType) Operand {
    const id = self.fresh()
    self.func.add_param(BlockParam { id = id, ty = ty })
    return Operand.Local(id)
}

// Create the entry block. The function's parameters (declared via
// `.param()`) are already in scope.
pub fn entry(self: &FunctionBuilder) BlockBuilder {
    let none: List(IrType) = list(0, self.allocator)
    return self.block_internal("entry", none)
}

// Add a non-entry block with `label`. `param_types` is the list of types
// for the block's parameters (commonly empty; non-empty for loop heads
// receiving values via `br`).
pub fn block(self: &FunctionBuilder, label: String, param_types: List(IrType)) BlockBuilder {
    return self.block_internal(label, param_types)
}

pub fn block(self: &FunctionBuilder, label: String) BlockBuilder {
    let none: List(IrType) = list(0, self.allocator)
    return self.block_internal(label, none)
}

pub fn block(self: &FunctionBuilder, label: String, p0: IrType) BlockBuilder {
    let types: List(IrType) = list(1, self.allocator)
    types.push(p0)
    return self.block_internal(label, types)
}

pub fn block(self: &FunctionBuilder, label: String, p0: IrType, p1: IrType) BlockBuilder {
    let types: List(IrType) = list(2, self.allocator)
    types.push(p0)
    types.push(p1)
    return self.block_internal(label, types)
}

fn block_internal(self: &FunctionBuilder, label: String, param_types: List(IrType)) BlockBuilder {
    let params: List(BlockParam) = list(param_types.len, self.allocator)
    for i in 0..param_types.len {
        const id = self.fresh()
        params.push(BlockParam { id = id, ty = param_types[i] })
    }
    param_types.deinit()
    let instrs: List(Instr) = list(0, self.allocator)
    let new_block = Block {
        label = label,
        params = params,
        instrs = instrs,
        terminator = Terminator.Unreachable,
    }
    const idx = self.func.add_block(new_block)
    return BlockBuilder { fb = self, block_idx = idx }
}

// Move the built function out. The builder must not be used afterwards.
pub fn finish(self: &FunctionBuilder) Function {
    return self.func
}

// ─────────────────────────────────────────────────────────────────────────
// BlockBuilder
// ─────────────────────────────────────────────────────────────────────────

pub type BlockBuilder = struct {
    fb: &FunctionBuilder
    block_idx: usize
}

// Access the i-th parameter of this block as an SSA operand.
pub fn param(self: &BlockBuilder, i: usize) Operand {
    const id = self.fb.func.blocks[self.block_idx].params[i].id
    return Operand.Local(id)
}

// Label of this block — useful when building `BlockTarget`s.
pub fn label(self: &BlockBuilder) String {
    return self.fb.func.blocks[self.block_idx].label
}

// ─────────────────────────────────────────────────────────────────────────
// Two-operand arithmetic / bitwise
// ─────────────────────────────────────────────────────────────────────────

pub fn iadd(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.IAdd, ty, lhs, rhs)
}
pub fn isub(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.ISub, ty, lhs, rhs)
}
pub fn imul(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.IMul, ty, lhs, rhs)
}
pub fn sdiv(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.SDiv, ty, lhs, rhs)
}
pub fn udiv(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.UDiv, ty, lhs, rhs)
}
pub fn srem(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.SRem, ty, lhs, rhs)
}
pub fn urem(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.URem, ty, lhs, rhs)
}
pub fn iand(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.IAnd, ty, lhs, rhs)
}
pub fn ior(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.IOr, ty, lhs, rhs)
}
pub fn ixor(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.IXor, ty, lhs, rhs)
}
pub fn ishl(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.IShl, ty, lhs, rhs)
}
pub fn ushr(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.UShr, ty, lhs, rhs)
}
pub fn sshr(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.SShr, ty, lhs, rhs)
}
pub fn fadd(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.FAdd, ty, lhs, rhs)
}
pub fn fsub(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.FSub, ty, lhs, rhs)
}
pub fn fmul(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.FMul, ty, lhs, rhs)
}
pub fn fdiv(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.binary(BinaryOp.FDiv, ty, lhs, rhs)
}

fn binary(self: &BlockBuilder, op: BinaryOp, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Binary(BinaryInstr {
        result = id, op = op, ty = ty, lhs = lhs, rhs = rhs
    }))
    return Operand.Local(id)
}

// ─────────────────────────────────────────────────────────────────────────
// Unary
// ─────────────────────────────────────────────────────────────────────────

pub fn ineg(self: &BlockBuilder, ty: IrType, v: Operand) Operand {
    return self.unary(UnaryOp.INeg, ty, v)
}
pub fn fneg(self: &BlockBuilder, ty: IrType, v: Operand) Operand {
    return self.unary(UnaryOp.FNeg, ty, v)
}

fn unary(self: &BlockBuilder, op: UnaryOp, ty: IrType, v: Operand) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Unary(UnaryInstr {
        result = id, op = op, ty = ty, operand = v
    }))
    return Operand.Local(id)
}

// ─────────────────────────────────────────────────────────────────────────
// Compare
// ─────────────────────────────────────────────────────────────────────────

pub fn icmp_eq(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpEq, ty, lhs, rhs)
}
pub fn icmp_ne(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpNe, ty, lhs, rhs)
}
pub fn icmp_slt(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpSlt, ty, lhs, rhs)
}
pub fn icmp_sle(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpSle, ty, lhs, rhs)
}
pub fn icmp_sgt(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpSgt, ty, lhs, rhs)
}
pub fn icmp_sge(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpSge, ty, lhs, rhs)
}
pub fn icmp_ult(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpUlt, ty, lhs, rhs)
}
pub fn icmp_ule(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpUle, ty, lhs, rhs)
}
pub fn icmp_ugt(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpUgt, ty, lhs, rhs)
}
pub fn icmp_uge(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.IcmpUge, ty, lhs, rhs)
}
pub fn fcmp_eq(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.FcmpEq, ty, lhs, rhs)
}
pub fn fcmp_ne(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.FcmpNe, ty, lhs, rhs)
}
pub fn fcmp_lt(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.FcmpLt, ty, lhs, rhs)
}
pub fn fcmp_le(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.FcmpLe, ty, lhs, rhs)
}
pub fn fcmp_gt(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.FcmpGt, ty, lhs, rhs)
}
pub fn fcmp_ge(self: &BlockBuilder, ty: IrType, lhs: Operand, rhs: Operand) Operand {
    return self.compare(CompareOp.FcmpGe, ty, lhs, rhs)
}

fn compare(self: &BlockBuilder, op: CompareOp, operand_ty: IrType, lhs: Operand, rhs: Operand) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Compare(CompareInstr {
        result = id, op = op, operand_ty = operand_ty, lhs = lhs, rhs = rhs
    }))
    return Operand.Local(id)
}

// ─────────────────────────────────────────────────────────────────────────
// Conversions
// ─────────────────────────────────────────────────────────────────────────

pub fn trunc(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.Trunc, src, dst, v)
}
pub fn zext(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.ZExt, src, dst, v)
}
pub fn sext(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.SExt, src, dst, v)
}
pub fn fptosi(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.FpToSi, src, dst, v)
}
pub fn fptoui(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.FpToUi, src, dst, v)
}
pub fn sitofp(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.SiToFp, src, dst, v)
}
pub fn uitofp(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.UiToFp, src, dst, v)
}
pub fn fpext(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.FpExt, src, dst, v)
}
pub fn fptrunc(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.FpTrunc, src, dst, v)
}
pub fn bitcast(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.Bitcast, src, dst, v)
}
pub fn ptrtoint(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.PtrToInt, src, dst, v)
}
pub fn inttoptr(self: &BlockBuilder, src: IrType, dst: IrType, v: Operand) Operand {
    return self.convert(ConvertOp.IntToPtr, src, dst, v)
}

fn convert(self: &BlockBuilder, op: ConvertOp, src: IrType, dst: IrType, v: Operand) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Convert(ConvertInstr {
        result = id, op = op, source_ty = src, result_ty = dst, operand = v
    }))
    return Operand.Local(id)
}

// ─────────────────────────────────────────────────────────────────────────
// Memory
// ─────────────────────────────────────────────────────────────────────────

pub fn stack_slot(self: &BlockBuilder, size: u64, align: u64) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.StackSlot(StackSlotInstr {
        result = id, size = size, align = align
    }))
    return Operand.Local(id)
}

pub fn load(self: &BlockBuilder, ty: IrType, ptr: Operand) Operand {
    return self.load_aligned(ty, ptr, 0u64)
}

pub fn load_aligned(self: &BlockBuilder, ty: IrType, ptr: Operand, align: u64) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Load(LoadInstr {
        result = id, ty = ty, ptr = ptr, align = align
    }))
    return Operand.Local(id)
}

pub fn store(self: &BlockBuilder, ty: IrType, value: Operand, ptr: Operand) {
    self.store_aligned(ty, value, ptr, 0u64)
}

pub fn store_aligned(self: &BlockBuilder, ty: IrType, value: Operand, ptr: Operand, align: u64) {
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Store(StoreInstr {
        ty = ty, value = value, ptr = ptr, align = align
    }))
}

pub fn gep(self: &BlockBuilder, ptr: Operand, offset: Operand) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Gep(GepInstr {
        result = id, ptr = ptr, offset = offset
    }))
    return Operand.Local(id)
}

pub fn memcpy(self: &BlockBuilder, dst: Operand, src: Operand, size: Operand) {
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Memcpy(MemcpyInstr {
        dst = dst, src = src, size = size
    }))
}

pub fn memset(self: &BlockBuilder, dst: Operand, byte: Operand, size: Operand) {
    let block = &self.fb.func.blocks[self.block_idx]
    block.instrs.push(Instr.Memset(MemsetInstr {
        dst = dst, byte = byte, size = size
    }))
}

// ─────────────────────────────────────────────────────────────────────────
// Calls
// ─────────────────────────────────────────────────────────────────────────

// Direct call returning a value. `args` ownership transfers in.
pub fn call(self: &BlockBuilder, callee: String, return_ty: IrType, args: List(Operand)) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    let var_types: List(IrType) = list(0, self.fb.allocator)
    let result: u32? = id
    let result_ty: IrType? = return_ty
    block.instrs.push(Instr.Call(CallInstr {
        result = result,
        result_ty = result_ty,
        callee = callee,
        args = args,
        variadic_arg_types = var_types,
    }))
    return Operand.Local(id)
}

// Direct call to a void function.
pub fn call_void(self: &BlockBuilder, callee: String, args: List(Operand)) {
    let block = &self.fb.func.blocks[self.block_idx]
    let var_types: List(IrType) = list(0, self.fb.allocator)
    let result: u32? = null
    let result_ty: IrType? = null
    block.instrs.push(Instr.Call(CallInstr {
        result = result,
        result_ty = result_ty,
        callee = callee,
        args = args,
        variadic_arg_types = var_types,
    }))
}

// One-arg direct call returning a value. Allocates the args list.
pub fn call_one(self: &BlockBuilder, callee: String, return_ty: IrType, a0: Operand) Operand {
    let args: List(Operand) = list(1, self.fb.allocator)
    args.push(a0)
    return self.call(callee, return_ty, args)
}

pub fn call_two(self: &BlockBuilder, callee: String, return_ty: IrType, a0: Operand, a1: Operand) Operand {
    let args: List(Operand) = list(2, self.fb.allocator)
    args.push(a0)
    args.push(a1)
    return self.call(callee, return_ty, args)
}

// Variadic foreign call. `fixed_args` are the named parameters of the
// foreign decl; `extras` are the variadic portion with explicit types.
pub fn call_variadic(self: &BlockBuilder, callee: String, return_ty: IrType, fixed_args: List(Operand), extras: List((IrType, Operand))) Operand {
    const id = self.fb.fresh()
    let block = &self.fb.func.blocks[self.block_idx]
    let var_types: List(IrType) = list(extras.len, self.fb.allocator)
    for i in 0..extras.len {
        fixed_args.push(extras[i].1)
        var_types.push(extras[i].0)
    }
    extras.deinit()
    let result: u32? = id
    let result_ty: IrType? = return_ty
    block.instrs.push(Instr.Call(CallInstr {
        result = result,
        result_ty = result_ty,
        callee = callee,
        args = fixed_args,
        variadic_arg_types = var_types,
    }))
    return Operand.Local(id)
}

// ─────────────────────────────────────────────────────────────────────────
// Terminators
// ─────────────────────────────────────────────────────────────────────────

// Return a value.
pub fn ret(self: &BlockBuilder, value: Operand) {
    let block = &self.fb.func.blocks[self.block_idx]
    let v: Operand? = value
    block.set_terminator(Terminator.Ret(v))
}

// Return from a void function.
pub fn ret_void(self: &BlockBuilder) {
    let block = &self.fb.func.blocks[self.block_idx]
    let v: Operand? = null
    block.set_terminator(Terminator.Ret(v))
}

// Unconditional branch to `label` with no block args.
pub fn br(self: &BlockBuilder, label: String) {
    let args: List(Operand) = list(0, self.fb.allocator)
    self.br_args(label, args)
}

// Unconditional branch with block arguments (passes ownership of args).
pub fn br_args(self: &BlockBuilder, label: String, args: List(Operand)) {
    let block = &self.fb.func.blocks[self.block_idx]
    block.set_terminator(Terminator.Br(BlockTarget { label = label, args = args }))
}

// Conditional branch to `then_label` / `else_label` with no block args.
pub fn br_if(self: &BlockBuilder, cond: Operand, then_label: String, else_label: String) {
    let t_args: List(Operand) = list(0, self.fb.allocator)
    let e_args: List(Operand) = list(0, self.fb.allocator)
    self.br_if_args(cond, then_label, t_args, else_label, e_args)
}

// Conditional branch with block arguments on each edge.
pub fn br_if_args(self: &BlockBuilder, cond: Operand, then_label: String, then_args: List(Operand), else_label: String, else_args: List(Operand)) {
    let block = &self.fb.func.blocks[self.block_idx]
    block.set_terminator(Terminator.BrIf(BrIfTerm {
        cond = cond,
        then_target = BlockTarget { label = then_label, args = then_args },
        else_target = BlockTarget { label = else_label, args = else_args },
    }))
}

pub fn unreachable(self: &BlockBuilder) {
    let block = &self.fb.func.blocks[self.block_idx]
    block.set_terminator(Terminator.Unreachable)
}
