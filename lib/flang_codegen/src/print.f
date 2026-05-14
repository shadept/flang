// Text-format printer for FIR. Output matches the canonical form in
// `docs/fir.md`.

import std.list
import std.option
import std.string
import std.string_builder
import flang_codegen.fir

// Render a whole module.
pub fn print(m: &Module, sb: &StringBuilder) {
    let need_blank = false

    for i in 0..m.globals.len {
        print_global(&m.globals[i], sb)
        sb.append("\n")
        need_blank = true
    }
    for i in 0..m.foreigns.len {
        if need_blank and i == 0 { sb.append("\n") }
        print_foreign(&m.foreigns[i], sb)
        sb.append("\n")
        need_blank = true
    }
    for i in 0..m.functions.len {
        if need_blank { sb.append("\n") }
        print_function(&m.functions[i], sb)
        need_blank = true
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Module-level declarations
// ─────────────────────────────────────────────────────────────────────────

fn print_global(g: &Global, sb: &StringBuilder) {
    sb.append("global @")
    sb.append(g.name)
    sb.append(" size=")
    sb.append(g.size)
    sb.append(" align=")
    sb.append(g.align)
    g.init_bytes match {
        Some(bytes) => {
            sb.append(" = ")
            print_byte_literal(bytes, sb)
        }
        None => {}
    }
}

fn print_foreign(f: &ForeignDecl, sb: &StringBuilder) {
    sb.append("foreign fn @")
    sb.append(f.name)
    sb.append("(")
    for i in 0..f.param_types.len {
        if i > 0 { sb.append(", ") }
        sb.append(f.param_types[i].name())
    }
    if f.variadic {
        if f.param_types.len > 0 { sb.append(", ") }
        sb.append("...")
    }
    sb.append(")")
    f.return_ty match {
        Some(ty) => { sb.append(" -> "); sb.append(ty.name()) }
        None => {}
    }
    if f.cc != CallConv.C {
        sb.append(" cc(")
        sb.append(f.cc.name())
        sb.append(")")
    }
}

fn print_function(f: &Function, sb: &StringBuilder) {
    sb.append("fn @")
    sb.append(f.name)
    sb.append("(")
    for i in 0..f.params.len {
        if i > 0 { sb.append(", ") }
        print_value_def(f.params[i].id, f.params[i].ty, sb)
    }
    if f.variadic {
        if f.params.len > 0 { sb.append(", ") }
        sb.append("...")
    }
    sb.append(")")
    f.return_ty match {
        Some(ty) => { sb.append(" -> "); sb.append(ty.name()) }
        None => {}
    }
    if f.cc != CallConv.C {
        sb.append(" cc(")
        sb.append(f.cc.name())
        sb.append(")")
    }
    sb.append(" {\n")
    for i in 0..f.blocks.len {
        if i > 0 { sb.append("\n") }
        print_block(&f.blocks[i], sb)
    }
    sb.append("}\n")
}

// ─────────────────────────────────────────────────────────────────────────
// Blocks
// ─────────────────────────────────────────────────────────────────────────

fn print_block(b: &Block, sb: &StringBuilder) {
    sb.append(b.label)
    if b.params.len > 0 {
        sb.append("(")
        for i in 0..b.params.len {
            if i > 0 { sb.append(", ") }
            print_value_def(b.params[i].id, b.params[i].ty, sb)
        }
        sb.append(")")
    }
    sb.append(":\n")
    for i in 0..b.instrs.len {
        sb.append("    ")
        print_instr(&b.instrs[i], sb)
        sb.append("\n")
    }
    sb.append("    ")
    print_terminator(&b.terminator, sb)
    sb.append("\n")
}

// ─────────────────────────────────────────────────────────────────────────
// Instructions
// ─────────────────────────────────────────────────────────────────────────

fn print_instr(i: &Instr, sb: &StringBuilder) {
    i.* match {
        Binary(b) => print_binary(&b, sb),
        Unary(u) => print_unary(&u, sb),
        Compare(c) => print_compare(&c, sb),
        Convert(c) => print_convert(&c, sb),
        StackSlot(s) => print_stack_slot(&s, sb),
        Load(l) => print_load(&l, sb),
        Store(s) => print_store(&s, sb),
        Gep(g) => print_gep(&g, sb),
        Memcpy(m) => print_memcpy(&m, sb),
        Memset(m) => print_memset(&m, sb),
        Call(c) => print_call(&c, sb),
        CallIndirect(c) => print_call_indirect(&c, sb),
    }
}

fn print_binary(b: &BinaryInstr, sb: &StringBuilder) {
    print_value_def(b.result, b.ty, sb)
    sb.append(" = ")
    sb.append(b.op.name())
    sb.append(" ")
    print_operand(&b.lhs, sb)
    sb.append(", ")
    print_operand(&b.rhs, sb)
}

fn print_unary(u: &UnaryInstr, sb: &StringBuilder) {
    print_value_def(u.result, u.ty, sb)
    sb.append(" = ")
    sb.append(u.op.name())
    sb.append(" ")
    print_operand(&u.operand, sb)
}

fn print_compare(c: &CompareInstr, sb: &StringBuilder) {
    print_value_def(c.result, IrType.I8, sb)
    sb.append(" = ")
    sb.append(c.op.name())
    sb.append(" ")
    print_operand(&c.lhs, sb)
    sb.append(", ")
    print_operand(&c.rhs, sb)
}

fn print_convert(c: &ConvertInstr, sb: &StringBuilder) {
    print_value_def(c.result, c.result_ty, sb)
    sb.append(" = ")
    sb.append(c.op.name())
    sb.append(".")
    sb.append(c.result_ty.name())
    sb.append(" ")
    print_operand(&c.operand, sb)
}

fn print_stack_slot(s: &StackSlotInstr, sb: &StringBuilder) {
    print_value_def(s.result, IrType.Ptr, sb)
    sb.append(" = stack_slot ")
    sb.append(s.size)
    sb.append(", ")
    sb.append(s.align)
}

fn print_load(l: &LoadInstr, sb: &StringBuilder) {
    print_value_def(l.result, l.ty, sb)
    sb.append(" = load.")
    sb.append(l.ty.name())
    sb.append(" ")
    print_operand(&l.ptr, sb)
    if l.align != 0 and l.align != l.ty.byte_align() as u64 {
        sb.append(" align ")
        sb.append(l.align)
    }
}

fn print_store(s: &StoreInstr, sb: &StringBuilder) {
    sb.append("store.")
    sb.append(s.ty.name())
    sb.append(" ")
    print_operand(&s.value, sb)
    sb.append(", ")
    print_operand(&s.ptr, sb)
    if s.align != 0 and s.align != s.ty.byte_align() as u64 {
        sb.append(" align ")
        sb.append(s.align)
    }
}

fn print_gep(g: &GepInstr, sb: &StringBuilder) {
    print_value_def(g.result, IrType.Ptr, sb)
    sb.append(" = gep ")
    print_operand(&g.ptr, sb)
    sb.append(", ")
    print_operand(&g.offset, sb)
}

fn print_memcpy(m: &MemcpyInstr, sb: &StringBuilder) {
    sb.append("memcpy ")
    print_operand(&m.dst, sb)
    sb.append(", ")
    print_operand(&m.src, sb)
    sb.append(", ")
    print_operand(&m.size, sb)
}

fn print_memset(m: &MemsetInstr, sb: &StringBuilder) {
    sb.append("memset ")
    print_operand(&m.dst, sb)
    sb.append(", ")
    print_operand(&m.byte, sb)
    sb.append(", ")
    print_operand(&m.size, sb)
}

fn print_call(c: &CallInstr, sb: &StringBuilder) {
    c.result match {
        Some(id) => {
            c.result_ty match {
                Some(ty) => { print_value_def(id, ty, sb); sb.append(" = ") },
                None => {},
            }
        },
        None => {},
    }
    sb.append("call @")
    sb.append(c.callee)
    sb.append("(")
    print_call_args(&c.args, &c.variadic_arg_types, sb)
    sb.append(")")
}

fn print_call_indirect(c: &CallIndirectInstr, sb: &StringBuilder) {
    c.result match {
        Some(id) => {
            c.result_ty match {
                Some(ty) => { print_value_def(id, ty, sb); sb.append(" = ") },
                None => {},
            }
        },
        None => {},
    }
    sb.append("call_indirect (")
    for i in 0..c.param_types.len {
        if i > 0 { sb.append(", ") }
        sb.append(c.param_types[i].name())
    }
    sb.append(") ")
    c.result_ty match {
        Some(ty) => { sb.append("-> "); sb.append(ty.name()); sb.append(" ") },
        None => {},
    }
    print_operand(&c.fn_ptr, sb)
    sb.append("(")
    print_call_args(&c.args, &c.variadic_arg_types, sb)
    sb.append(")")
}

fn print_call_args(args: &List(Operand), variadic_types: &List(IrType), sb: &StringBuilder) {
    const fixed_count = args.len - variadic_types.len
    for i in 0..fixed_count {
        if i > 0 { sb.append(", ") }
        print_operand(&args[i], sb)
    }
    if variadic_types.len > 0 {
        if fixed_count > 0 { sb.append(", ") }
        sb.append("...")
        for i in 0..variadic_types.len {
            sb.append(", ")
            sb.append(variadic_types[i].name())
            sb.append(" ")
            print_operand(&args[fixed_count + i], sb)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Terminators
// ─────────────────────────────────────────────────────────────────────────

fn print_terminator(t: &Terminator, sb: &StringBuilder) {
    t.* match {
        Br(tgt) => { sb.append("br "); print_block_target(&tgt, sb) },
        BrIf(b) => {
            sb.append("br_if ")
            print_operand(&b.cond, sb)
            sb.append(", ")
            print_block_target(&b.then_target, sb)
            sb.append(", ")
            print_block_target(&b.else_target, sb)
        },
        Ret(v) => {
            sb.append("ret")
            v match {
                Some(op) => { sb.append(" "); print_operand(&op, sb) },
                None => {},
            }
        },
        Unreachable => sb.append("unreachable"),
    }
}

fn print_block_target(t: &BlockTarget, sb: &StringBuilder) {
    sb.append(t.label)
    if t.args.len > 0 {
        sb.append("(")
        for i in 0..t.args.len {
            if i > 0 { sb.append(", ") }
            print_operand(&t.args[i], sb)
        }
        sb.append(")")
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Operands and value definitions
// ─────────────────────────────────────────────────────────────────────────

fn print_value_def(id: u32, ty: IrType, sb: &StringBuilder) {
    sb.append("%v")
    sb.append(id)
    sb.append(": ")
    sb.append(ty.name())
}

fn print_operand(op: &Operand, sb: &StringBuilder) {
    op.* match {
        Local(id) => { sb.append("%v"); sb.append(id) },
        IntConst(n) => sb.append(n),
        FloatConst(f) => sb.append(f),
        NullPtr => sb.append("null"),
        GlobalRef(name) => { sb.append("@"); sb.append(name) },
        FuncRef(name) => { sb.append("@"); sb.append(name) },
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Opcode mnemonics
// ─────────────────────────────────────────────────────────────────────────

pub fn name(op: BinaryOp) String {
    return op match {
        IAdd => "iadd",
        ISub => "isub",
        IMul => "imul",
        SDiv => "sdiv",
        UDiv => "udiv",
        SRem => "srem",
        URem => "urem",
        IAnd => "iand",
        IOr => "ior",
        IXor => "ixor",
        IShl => "ishl",
        UShr => "ushr",
        SShr => "sshr",
        FAdd => "fadd",
        FSub => "fsub",
        FMul => "fmul",
        FDiv => "fdiv",
    }
}

pub fn name(op: UnaryOp) String {
    return op match {
        INeg => "ineg",
        FNeg => "fneg",
    }
}

pub fn name(op: CompareOp) String {
    return op match {
        IcmpEq => "icmp.eq",
        IcmpNe => "icmp.ne",
        IcmpSlt => "icmp.slt",
        IcmpSle => "icmp.sle",
        IcmpSgt => "icmp.sgt",
        IcmpSge => "icmp.sge",
        IcmpUlt => "icmp.ult",
        IcmpUle => "icmp.ule",
        IcmpUgt => "icmp.ugt",
        IcmpUge => "icmp.uge",
        FcmpEq => "fcmp.eq",
        FcmpNe => "fcmp.ne",
        FcmpLt => "fcmp.lt",
        FcmpLe => "fcmp.le",
        FcmpGt => "fcmp.gt",
        FcmpGe => "fcmp.ge",
    }
}

pub fn name(op: ConvertOp) String {
    return op match {
        Trunc => "trunc",
        ZExt => "zext",
        SExt => "sext",
        FpToSi => "fptosi",
        FpToUi => "fptoui",
        SiToFp => "sitofp",
        UiToFp => "uitofp",
        FpExt => "fpext",
        FpTrunc => "fptrunc",
        Bitcast => "bitcast",
        PtrToInt => "ptrtoint",
        IntToPtr => "inttoptr",
    }
}

fn print_byte_literal(bytes: u8[], sb: &StringBuilder) {
    sb.append("\"")
    for i in 0..bytes.len {
        const b = bytes[i]
        if b == '\\' { sb.append("\\\\") }
        else if b == '"' { sb.append("\\\"") }
        else if b == '\n' { sb.append("\\n") }
        else if b == '\r' { sb.append("\\r") }
        else if b == '\t' { sb.append("\\t") }
        else if b == 0 { sb.append("\\0") }
        else if b >= 0x20 and b < 0x7F { sb.append_byte(b) }
        else {
            sb.append("\\x")
            sb.append_byte(hex_nibble(b >> 4))
            sb.append_byte(hex_nibble(b & 0x0F))
        }
    }
    sb.append("\"")
}

fn hex_nibble(n: u8) u8 {
    if n < 10 { return '0' + n }
    return 'a' + (n - 10)
}

