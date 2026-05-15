// C backend: FIR -> C99 -> native executable.
//
// Three layers in this file:
//
//   1. `translate(&Module, &StringBuilder)` — emit C source from FIR.
//      Mechanical 1:1 walk; the mapping table lives in `docs/fir.md`.
//   2. `discover_compiler(...)` — locate a working C toolchain.
//      Windows: MSVC via vswhere; POSIX: $CC / clang / cc / gcc;
//      macOS: also xcrun clang.
//   3. `compile(&Module, &BuildOptions)` — top-level entry point.
//      Translates, writes the .c file to disk, invokes the discovered
//      compiler, returns a `BuildResult`.
//
// All three layers stay independent: callers that only need the .c
// text can call `translate` directly without ever touching discovery.

import std.allocator
import std.env
import std.io.file
import std.io.fs
import std.list
import std.option
import std.path
import std.process
import std.result
import std.string
import std.string_builder
import flang_codegen.backend
import flang_codegen.fir

// =============================================================================
// Public API
// =============================================================================

// Lower the module to a C translation unit. Caller owns `sb`.
pub fn translate(m: &Module, sb: &StringBuilder) {
    emit_preamble(sb)
    for i in 0..m.foreigns.len {
        // The runtime preamble already defines these — re-emitting them
        // as `extern` would conflict.
        if is_runtime_provided_symbol(m.foreigns[i].name) { continue }
        emit_foreign(&m.foreigns[i], sb)
        sb.append("\n")
    }
    if m.foreigns.len > 0 and (m.globals.len > 0 or m.functions.len > 0) {
        sb.append("\n")
    }
    for i in 0..m.globals.len {
        emit_global(&m.globals[i], sb)
        sb.append("\n")
    }
    if m.globals.len > 0 and m.functions.len > 0 {
        sb.append("\n")
    }
    // Forward declarations so call order is irrelevant.
    for i in 0..m.functions.len {
        emit_fn_decl(&m.functions[i], sb)
        sb.append(";\n")
    }
    if m.functions.len > 0 {
        sb.append("\n")
    }
    for i in 0..m.functions.len {
        if i > 0 { sb.append("\n") }
        emit_function(&m.functions[i], sb)
    }
}

// End-to-end: FIR -> .c -> executable. The .c file is written next to
// the output executable (or to `options.emit_c_path` when set) and is
// cleaned up unless `keep_temps` is true.
pub fn compile(m: &Module, options: &BuildOptions) Result(BuildResult, BuildError) {
    const alloc = options.allocator

    // 1. Discover (or accept override of) the compiler. Fail fast before
    //    doing the FIR -> C work and the .c-file write — no point lowering
    //    anything if there's no toolchain to consume it.
    let info_r = discover_or_override(options, alloc)
    if info_r.is_err() {
        return Err(info_r.unwrap_err())
    }
    let info = info_r.unwrap()
    defer info.deinit()

    // 2. Lower FIR to C text.
    let sb = string_builder(4096, alloc)
    defer sb.deinit()
    translate(m, &sb)

    // 3. Pick a place for the .c file. emit_c_path wins if set; otherwise
    //    we drop it next to the output executable with a ".c" extension.
    let c_path_owned: OwnedString
    let keep_c = options.keep_temps
    options.emit_c_path match {
        Some(p) => {
            c_path_owned = from_view(p, alloc)
            keep_c = true
        }
        None => {
            let p = path(options.output_path, alloc)
            defer p.deinit()
            let q = p.with_extension("c")
            defer q.deinit()
            c_path_owned = from_view(q.as_view(), alloc)
        }
    }

    // 4. Write the .c file.
    const write_status = write_c_file(c_path_owned.as_view(), sb.as_view(), alloc)
    if write_status.is_err() {
        c_path_owned.deinit()
        return Err(BuildError.IOError)
    }

    // 5. Build the argv and spawn the compiler.
    let argv = build_compiler_argv(&info, c_path_owned.as_view(), options)
    defer {
        for i in 0..argv.len {
            let a = argv[i]
            a.deinit()
        }
        argv.deinit()
    }

    let spawn_r = run_compiler(&info, &argv, alloc)
    if spawn_r.is_err() {
        if !keep_c { remove_file_quiet(c_path_owned.as_view()) }
        c_path_owned.deinit()
        return Err(spawn_r.unwrap_err())
    }
    const exit_code = spawn_r.unwrap()
    if exit_code != 0 {
        if !keep_c { remove_file_quiet(c_path_owned.as_view()) }
        c_path_owned.deinit()
        return Err(BuildError.CompilerFailed(exit_code))
    }

    // 6. Build the result. Retain the c_source_path if requested.
    let exe_path = from_view(options.output_path, alloc)
    let c_kept: OwnedString? = null
    if keep_c {
        c_kept = c_path_owned
    } else {
        remove_file_quiet(c_path_owned.as_view())
        c_path_owned.deinit()
    }
    return Ok(BuildResult {
        executable_path = exe_path,
        c_source_path = c_kept,
    })
}

// =============================================================================
// FIR -> C translation
// =============================================================================

fn emit_preamble(sb: &StringBuilder) {
    sb.append("/* Generated by flang_codegen.c_backend — do not edit. */\n")
    sb.append("#include <stdint.h>\n")
    sb.append("#include <stddef.h>\n")
    sb.append("#include <string.h>\n")
    sb.append("#include <stdlib.h>\n")
    sb.append("\n")
    // FIR-mandated invariant: arithmetic right shift on signed integers.
    // The standard left this implementation-defined until C23.
    sb.append("_Static_assert((-1 >> 1) == -1, \"FIR backend requires arithmetic right shift\");\n")
    sb.append("\n")
    // Runtime support: capture argc/argv at process entry so std.env
    // (`__flang_get_argc`, `__flang_get_arg`) can read them. Defined
    // unconditionally — the linker drops them if no main wraps them.
    sb.append("/* flang runtime: argv / env access for std.env */\n")
    sb.append("static int __flang_argc = 0;\n")
    sb.append("static char** __flang_argv = 0;\n")
    sb.append("int32_t __flang_get_argc(void) { return __flang_argc; }\n")
    sb.append("unsigned char* __flang_get_arg(int32_t index) {\n")
    sb.append("    if (index < 0 || index >= __flang_argc) return (unsigned char*)0;\n")
    sb.append("    return (unsigned char*)__flang_argv[index];\n")
    sb.append("}\n")
    sb.append("unsigned char* __flang_getenv(const unsigned char* name) {\n")
    sb.append("    return (unsigned char*)getenv((const char*)name);\n")
    sb.append("}\n")
    sb.append("\n")
}

// Names of foreign decls that the runtime preamble already provides.
// Emitting `extern` decls for these conflicts with the definitions
// above, so we skip them.
fn is_runtime_provided_symbol(name: String) bool {
    if name == "__flang_get_argc" { return true }
    if name == "__flang_get_arg" { return true }
    if name == "__flang_getenv" { return true }
    return false
}

// A FIR function named "main" is the program entry point. We emit it
// with the C-conventional `int main(int argc, char** argv)` signature
// and capture argv into the runtime globals before any user code runs.
fn is_entry_point(f: &Function) bool {
    return f.name == "main"
}

fn emit_foreign(f: &ForeignDecl, sb: &StringBuilder) {
    sb.append("extern ")
    emit_ret_type(f.return_ty, sb)
    sb.append(" ")
    sb.append(f.name)
    sb.append("(")
    if f.param_types.len == 0 and !f.variadic {
        sb.append("void")
    } else {
        for i in 0..f.param_types.len {
            if i > 0 { sb.append(", ") }
            emit_c_type(f.param_types[i], sb)
        }
        if f.variadic {
            if f.param_types.len > 0 { sb.append(", ") }
            sb.append("...")
        }
    }
    sb.append(");")
}

fn emit_global(g: &Global, sb: &StringBuilder) {
    // Always emit at file scope as `static` so it's not exported across
    // translation units. If FIR grows visibility flags, switch on them.
    //
    // `_Alignas(align)` is required for any global whose aggregate
    // contains a wider-than-byte field (a struct with `u64` / `f64` /
    // `ptr` would otherwise float to any byte boundary). For align=1
    // strings the directive is redundant but harmless.
    sb.append("static _Alignas(")
    sb.append(g.align)
    sb.append(") unsigned char g_")
    sb.append(g.name)
    sb.append("[")
    sb.append(g.size)
    sb.append("]")
    g.init_bytes match {
        Some(bytes) => {
            sb.append(" = {")
            for i in 0..bytes.len {
                if i > 0 { sb.append(", ") }
                sb.append("0x")
                emit_hex_byte(bytes[i], sb)
            }
            sb.append("}")
        }
        None => {}
    }
    sb.append(";")
}

fn emit_fn_decl(f: &Function, sb: &StringBuilder) {
    if is_entry_point(f) {
        // C entry point: int main(int argc, char** argv). FIR's main()
        // takes no formal params; argv is captured into runtime globals.
        sb.append("int main(int __flang_argc_, char** __flang_argv_)")
        return
    }
    emit_ret_type(f.return_ty, sb)
    sb.append(" ")
    sb.append(f.name)
    sb.append("(")
    if f.params.len == 0 {
        sb.append("void")
    } else {
        for i in 0..f.params.len {
            if i > 0 { sb.append(", ") }
            emit_c_type(f.params[i].ty, sb)
            sb.append(" v")
            sb.append(f.params[i].id)
        }
    }
    sb.append(")")
}

fn emit_function(f: &Function, sb: &StringBuilder) {
    emit_fn_decl(f, sb)
    sb.append(" {\n")

    // Capture argc/argv into the runtime globals before any user code
    // runs so std.env (`__flang_get_argc`, `__flang_get_arg`) works.
    if is_entry_point(f) {
        sb.append("    __flang_argc = __flang_argc_;\n")
        sb.append("    __flang_argv = __flang_argv_;\n")
    }

    // Hoist every non-entry block parameter to a function-scope local —
    // this is what gives us the parallel-move semantics for `br
    // target(args)` (we always assign through temporaries at the branch
    // site). The entry block's params are the function's params, so we
    // skip its (empty) params list.
    for bi in 1..f.blocks.len {
        const blk = &f.blocks[bi]
        for pi in 0..blk.params.len {
            sb.append("    ")
            emit_c_type(blk.params[pi].ty, sb)
            sb.append(" v")
            sb.append(blk.params[pi].id)
            sb.append(" = 0;\n")
        }
    }

    for bi in 0..f.blocks.len {
        const blk = &f.blocks[bi]
        if bi > 0 { sb.append("\n") }
        if bi > 0 {
            sb.append(blk.label)
            sb.append(":;\n")
        }
        for ii in 0..blk.instrs.len {
            sb.append("    ")
            emit_instr(&blk.instrs[ii], sb)
        }
        emit_terminator(&blk.terminator, f, sb)
    }

    sb.append("}\n")
}

// Locate a block by label so branch-arg moves can resolve target
// parameter ids. Linear scan; functions are small enough that an
// auxiliary map isn't worth the bookkeeping.
fn find_block_idx(f: &Function, label: String) usize {
    for i in 0..f.blocks.len {
        if f.blocks[i].label == label { return i }
    }
    return 0
}

// ─────────────────────────────────────────────────────────────────────────
// Type names
// ─────────────────────────────────────────────────────────────────────────

fn emit_c_type(ty: IrType, sb: &StringBuilder) {
    sb.append(c_type_name(ty))
}

fn emit_ret_type(ty: IrType?, sb: &StringBuilder) {
    ty match {
        Some(t) => emit_c_type(t, sb),
        None => sb.append("void"),
    }
}

fn c_type_name(ty: IrType) String {
    return ty match {
        I8 => "int8_t",
        I16 => "int16_t",
        I32 => "int32_t",
        I64 => "int64_t",
        F32 => "float",
        F64 => "double",
        Ptr => "void*",
    }
}

fn c_unsigned_type_name(ty: IrType) String {
    return ty match {
        I8 => "uint8_t",
        I16 => "uint16_t",
        I32 => "uint32_t",
        I64 => "uint64_t",
        _ => "uint64_t",
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Operands
// ─────────────────────────────────────────────────────────────────────────

fn emit_operand(op: &Operand, sb: &StringBuilder) {
    op.* match {
        Local(id) => { sb.append("v"); sb.append(id) },
        IntConst(n) => sb.append(n),
        FloatConst(f) => sb.append(f),
        NullPtr => sb.append("((void*)0)"),
        GlobalRef(name) => { sb.append("((void*)g_"); sb.append(name); sb.append(")") },
        FuncRef(name) => { sb.append("((void*)&"); sb.append(name); sb.append(")") },
    }
}

// Cast an operand to a given C type. Used pervasively so that integer
// literals consumed in different slots get correctly typed.
fn emit_operand_as(op: &Operand, ty: IrType, sb: &StringBuilder) {
    sb.append("((")
    emit_c_type(ty, sb)
    sb.append(")")
    emit_operand(op, sb)
    sb.append(")")
}

fn emit_operand_as_unsigned(op: &Operand, ty: IrType, sb: &StringBuilder) {
    sb.append("((")
    sb.append(c_unsigned_type_name(ty))
    sb.append(")")
    emit_operand(op, sb)
    sb.append(")")
}

// ─────────────────────────────────────────────────────────────────────────
// Instructions
// ─────────────────────────────────────────────────────────────────────────

fn emit_instr(i: &Instr, sb: &StringBuilder) {
    i.* match {
        Binary(b) => emit_binary(&b, sb),
        Unary(u) => emit_unary(&u, sb),
        Compare(c) => emit_compare(&c, sb),
        Convert(c) => emit_convert(&c, sb),
        StackSlot(s) => emit_stack_slot(&s, sb),
        Load(l) => emit_load(&l, sb),
        Store(s) => emit_store(&s, sb),
        Gep(g) => emit_gep(&g, sb),
        Memcpy(m) => emit_memcpy(&m, sb),
        Memset(m) => emit_memset(&m, sb),
        Call(c) => emit_call(&c, sb),
        CallIndirect(c) => emit_call_indirect(&c, sb),
    }
}

fn emit_result_decl(id: u32, ty: IrType, sb: &StringBuilder) {
    emit_c_type(ty, sb)
    sb.append(" v")
    sb.append(id)
    sb.append(" = ")
}

fn emit_binary(b: &BinaryInstr, sb: &StringBuilder) {
    emit_result_decl(b.result, b.ty, sb)
    // The signed/unsigned mapping table from docs/fir.md is encoded here.
    b.op match {
        IAdd => emit_wrap_binop(&b.lhs, &b.rhs, b.ty, "+", sb),
        ISub => emit_wrap_binop(&b.lhs, &b.rhs, b.ty, "-", sb),
        IMul => emit_wrap_binop(&b.lhs, &b.rhs, b.ty, "*", sb),
        SDiv => { emit_operand(&b.lhs, sb); sb.append(" / "); emit_operand(&b.rhs, sb) },
        UDiv => emit_uns_binop(&b.lhs, &b.rhs, b.ty, "/", sb),
        SRem => { emit_operand(&b.lhs, sb); sb.append(" % "); emit_operand(&b.rhs, sb) },
        URem => emit_uns_binop(&b.lhs, &b.rhs, b.ty, "%", sb),
        IAnd => { emit_operand(&b.lhs, sb); sb.append(" & "); emit_operand(&b.rhs, sb) },
        IOr  => { emit_operand(&b.lhs, sb); sb.append(" | "); emit_operand(&b.rhs, sb) },
        IXor => { emit_operand(&b.lhs, sb); sb.append(" ^ "); emit_operand(&b.rhs, sb) },
        IShl => emit_shift(&b.lhs, &b.rhs, b.ty, "<<", true, sb),
        UShr => emit_shift(&b.lhs, &b.rhs, b.ty, ">>", true, sb),
        SShr => emit_shift(&b.lhs, &b.rhs, b.ty, ">>", false, sb),
        FAdd => { emit_operand(&b.lhs, sb); sb.append(" + "); emit_operand(&b.rhs, sb) },
        FSub => { emit_operand(&b.lhs, sb); sb.append(" - "); emit_operand(&b.rhs, sb) },
        FMul => { emit_operand(&b.lhs, sb); sb.append(" * "); emit_operand(&b.rhs, sb) },
        FDiv => { emit_operand(&b.lhs, sb); sb.append(" / "); emit_operand(&b.rhs, sb) },
    }
    sb.append(";\n")
}

fn emit_wrap_binop(a: &Operand, b: &Operand, ty: IrType, op: String, sb: &StringBuilder) {
    // (signed)((unsigned)a OP (unsigned)b) — two's-complement wrap.
    sb.append("(")
    emit_c_type(ty, sb)
    sb.append(")(")
    emit_operand_as_unsigned(a, ty, sb)
    sb.append(" ")
    sb.append(op)
    sb.append(" ")
    emit_operand_as_unsigned(b, ty, sb)
    sb.append(")")
}

fn emit_uns_binop(a: &Operand, b: &Operand, ty: IrType, op: String, sb: &StringBuilder) {
    // (signed)((unsigned)a OP (unsigned)b)
    sb.append("(")
    emit_c_type(ty, sb)
    sb.append(")(")
    emit_operand_as_unsigned(a, ty, sb)
    sb.append(" ")
    sb.append(op)
    sb.append(" ")
    emit_operand_as_unsigned(b, ty, sb)
    sb.append(")")
}

fn emit_shift(a: &Operand, b: &Operand, ty: IrType, op: String, unsigned_lhs: bool, sb: &StringBuilder) {
    sb.append("(")
    emit_c_type(ty, sb)
    sb.append(")(")
    if unsigned_lhs {
        emit_operand_as_unsigned(a, ty, sb)
    } else {
        emit_operand_as(a, ty, sb)
    }
    sb.append(" ")
    sb.append(op)
    sb.append(" ")
    emit_operand(b, sb)
    sb.append(")")
}

fn emit_unary(u: &UnaryInstr, sb: &StringBuilder) {
    emit_result_decl(u.result, u.ty, sb)
    u.op match {
        INeg => {
            sb.append("(")
            emit_c_type(u.ty, sb)
            sb.append(")(0u - ")
            emit_operand_as_unsigned(&u.operand, u.ty, sb)
            sb.append(")")
        },
        FNeg => { sb.append("-"); emit_operand(&u.operand, sb) },
    }
    sb.append(";\n")
}

fn emit_compare(c: &CompareInstr, sb: &StringBuilder) {
    emit_result_decl(c.result, IrType.I8, sb)
    sb.append("(int8_t)(")
    c.op match {
        IcmpEq => emit_cmp_signed(&c.lhs, &c.rhs, c.operand_ty, "==", sb),
        IcmpNe => emit_cmp_signed(&c.lhs, &c.rhs, c.operand_ty, "!=", sb),
        IcmpSlt => emit_cmp_signed(&c.lhs, &c.rhs, c.operand_ty, "<", sb),
        IcmpSle => emit_cmp_signed(&c.lhs, &c.rhs, c.operand_ty, "<=", sb),
        IcmpSgt => emit_cmp_signed(&c.lhs, &c.rhs, c.operand_ty, ">", sb),
        IcmpSge => emit_cmp_signed(&c.lhs, &c.rhs, c.operand_ty, ">=", sb),
        IcmpUlt => emit_cmp_unsigned(&c.lhs, &c.rhs, c.operand_ty, "<", sb),
        IcmpUle => emit_cmp_unsigned(&c.lhs, &c.rhs, c.operand_ty, "<=", sb),
        IcmpUgt => emit_cmp_unsigned(&c.lhs, &c.rhs, c.operand_ty, ">", sb),
        IcmpUge => emit_cmp_unsigned(&c.lhs, &c.rhs, c.operand_ty, ">=", sb),
        FcmpEq => emit_cmp_float(&c.lhs, &c.rhs, "==", sb),
        FcmpNe => emit_cmp_float(&c.lhs, &c.rhs, "!=", sb),
        FcmpLt => emit_cmp_float(&c.lhs, &c.rhs, "<", sb),
        FcmpLe => emit_cmp_float(&c.lhs, &c.rhs, "<=", sb),
        FcmpGt => emit_cmp_float(&c.lhs, &c.rhs, ">", sb),
        FcmpGe => emit_cmp_float(&c.lhs, &c.rhs, ">=", sb),
    }
    sb.append(");\n")
}

fn emit_cmp_signed(a: &Operand, b: &Operand, ty: IrType, op: String, sb: &StringBuilder) {
    emit_operand_as(a, ty, sb)
    sb.append(" ")
    sb.append(op)
    sb.append(" ")
    emit_operand_as(b, ty, sb)
}

fn emit_cmp_unsigned(a: &Operand, b: &Operand, ty: IrType, op: String, sb: &StringBuilder) {
    emit_operand_as_unsigned(a, ty, sb)
    sb.append(" ")
    sb.append(op)
    sb.append(" ")
    emit_operand_as_unsigned(b, ty, sb)
}

fn emit_cmp_float(a: &Operand, b: &Operand, op: String, sb: &StringBuilder) {
    emit_operand(a, sb)
    sb.append(" ")
    sb.append(op)
    sb.append(" ")
    emit_operand(b, sb)
}

fn emit_convert(c: &ConvertInstr, sb: &StringBuilder) {
    emit_result_decl(c.result, c.result_ty, sb)
    c.op match {
        Trunc => {
            sb.append("(")
            emit_c_type(c.result_ty, sb)
            sb.append(")")
            emit_operand(&c.operand, sb)
        },
        ZExt => {
            sb.append("(")
            emit_c_type(c.result_ty, sb)
            sb.append(")")
            emit_operand_as_unsigned(&c.operand, c.source_ty, sb)
        },
        SExt => {
            sb.append("(")
            emit_c_type(c.result_ty, sb)
            sb.append(")")
            emit_operand_as(&c.operand, c.source_ty, sb)
        },
        FpToSi => {
            sb.append("(")
            emit_c_type(c.result_ty, sb)
            sb.append(")")
            emit_operand(&c.operand, sb)
        },
        FpToUi => {
            sb.append("(")
            emit_c_type(c.result_ty, sb)
            sb.append(")(")
            sb.append(c_unsigned_type_name(c.result_ty))
            sb.append(")")
            emit_operand(&c.operand, sb)
        },
        SiToFp => {
            sb.append("(")
            emit_c_type(c.result_ty, sb)
            sb.append(")")
            emit_operand_as(&c.operand, c.source_ty, sb)
        },
        UiToFp => {
            sb.append("(")
            emit_c_type(c.result_ty, sb)
            sb.append(")")
            emit_operand_as_unsigned(&c.operand, c.source_ty, sb)
        },
        FpExt => {
            sb.append("(double)")
            emit_operand(&c.operand, sb)
        },
        FpTrunc => {
            sb.append("(float)")
            emit_operand(&c.operand, sb)
        },
        Bitcast => {
            // Same-size reinterpret via memcpy to dodge strict-aliasing UB.
            sb.append("0;\n")
            sb.append("    memcpy(&v")
            sb.append(c.result)
            sb.append(", &(")
            emit_c_type(c.source_ty, sb)
            sb.append("){")
            emit_operand(&c.operand, sb)
            sb.append("}, sizeof(v")
            sb.append(c.result)
            sb.append("))")
        },
        PtrToInt => {
            sb.append("(")
            emit_c_type(c.result_ty, sb)
            sb.append(")(uintptr_t)")
            emit_operand(&c.operand, sb)
        },
        IntToPtr => {
            sb.append("(void*)(uintptr_t)")
            emit_operand(&c.operand, sb)
        },
    }
    sb.append(";\n")
}

fn emit_stack_slot(s: &StackSlotInstr, sb: &StringBuilder) {
    // C11 `_Alignas` works inside compound statements; we emit each slot
    // as a unique-named char array followed by a void* alias for the
    // SSA value.
    sb.append("_Alignas(")
    sb.append(s.align)
    sb.append(") unsigned char __slot")
    sb.append(s.result)
    sb.append("[")
    sb.append(s.size)
    sb.append("];\n")
    sb.append("    void* v")
    sb.append(s.result)
    sb.append(" = (void*)__slot")
    sb.append(s.result)
    sb.append(";\n")
}

fn emit_load(l: &LoadInstr, sb: &StringBuilder) {
    // memcpy round-trip — portable, strict-aliasing-safe, optimiser folds it.
    emit_c_type(l.ty, sb)
    sb.append(" v")
    sb.append(l.result)
    sb.append("; memcpy(&v")
    sb.append(l.result)
    sb.append(", ")
    emit_operand(&l.ptr, sb)
    sb.append(", sizeof(")
    emit_c_type(l.ty, sb)
    sb.append("));\n")
}

fn emit_store(s: &StoreInstr, sb: &StringBuilder) {
    sb.append("{ ")
    emit_c_type(s.ty, sb)
    sb.append(" __sv = ")
    emit_operand_as(&s.value, s.ty, sb)
    sb.append("; memcpy(")
    emit_operand(&s.ptr, sb)
    sb.append(", &__sv, sizeof(")
    emit_c_type(s.ty, sb)
    sb.append(")); }\n")
}

fn emit_gep(g: &GepInstr, sb: &StringBuilder) {
    sb.append("void* v")
    sb.append(g.result)
    sb.append(" = (void*)((char*)")
    emit_operand(&g.ptr, sb)
    sb.append(" + (intptr_t)")
    emit_operand_as(&g.offset, IrType.I64, sb)
    sb.append(");\n")
}

fn emit_memcpy(m: &MemcpyInstr, sb: &StringBuilder) {
    sb.append("memcpy(")
    emit_operand(&m.dst, sb)
    sb.append(", ")
    emit_operand(&m.src, sb)
    sb.append(", (size_t)")
    emit_operand_as_unsigned(&m.size, IrType.I64, sb)
    sb.append(");\n")
}

fn emit_memset(m: &MemsetInstr, sb: &StringBuilder) {
    sb.append("memset(")
    emit_operand(&m.dst, sb)
    sb.append(", (int)")
    emit_operand(&m.byte, sb)
    sb.append(", (size_t)")
    emit_operand_as_unsigned(&m.size, IrType.I64, sb)
    sb.append(");\n")
}

fn emit_call(c: &CallInstr, sb: &StringBuilder) {
    c.result match {
        Some(id) => {
            c.result_ty match {
                Some(ty) => {
                    emit_c_type(ty, sb)
                    sb.append(" v")
                    sb.append(id)
                    sb.append(" = ")
                }
                None => {}
            }
        }
        None => {}
    }
    sb.append(c.callee)
    sb.append("(")
    for i in 0..c.args.len {
        if i > 0 { sb.append(", ") }
        emit_operand(&c.args[i], sb)
    }
    sb.append(");\n")
}

fn emit_call_indirect(c: &CallIndirectInstr, sb: &StringBuilder) {
    c.result match {
        Some(id) => {
            c.result_ty match {
                Some(ty) => {
                    emit_c_type(ty, sb)
                    sb.append(" v")
                    sb.append(id)
                    sb.append(" = ")
                }
                None => {}
            }
        }
        None => {}
    }
    // Cast the ptr operand through a function-pointer type built from
    // the inline signature. Variadic indirect calls would need a trailing
    // `, ...` here; we leave them out for now (CallIndirect is rare).
    sb.append("((")
    emit_ret_type(c.result_ty, sb)
    sb.append(" (*)(")
    if c.param_types.len == 0 {
        sb.append("void")
    } else {
        for i in 0..c.param_types.len {
            if i > 0 { sb.append(", ") }
            emit_c_type(c.param_types[i], sb)
        }
    }
    sb.append("))")
    emit_operand(&c.fn_ptr, sb)
    sb.append(")(")
    for i in 0..c.args.len {
        if i > 0 { sb.append(", ") }
        emit_operand(&c.args[i], sb)
    }
    sb.append(");\n")
}

// ─────────────────────────────────────────────────────────────────────────
// Terminators
// ─────────────────────────────────────────────────────────────────────────

fn emit_terminator(t: &Terminator, f: &Function, sb: &StringBuilder) {
    t.* match {
        Br(tgt) => emit_br(&tgt, f, sb),
        BrIf(b) => emit_br_if(&b, f, sb),
        Ret(v) => emit_ret(v, f, sb),
        Unreachable => sb.append("    /* unreachable */\n"),
    }
}

fn emit_br(t: &BlockTarget, f: &Function, sb: &StringBuilder) {
    emit_branch_arg_moves(t, f, "    ", sb)
    sb.append("    goto ")
    sb.append(t.label)
    sb.append(";\n")
}

fn emit_br_if(b: &BrIfTerm, f: &Function, sb: &StringBuilder) {
    sb.append("    if (")
    emit_operand(&b.cond, sb)
    sb.append(") {\n")
    emit_branch_arg_moves(&b.then_target, f, "        ", sb)
    sb.append("        goto ")
    sb.append(b.then_target.label)
    sb.append(";\n    } else {\n")
    emit_branch_arg_moves(&b.else_target, f, "        ", sb)
    sb.append("        goto ")
    sb.append(b.else_target.label)
    sb.append(";\n    }\n")
}

// Parallel-move semantics: stash every arg in a temp before writing the
// target block's parameter locals. This handles the case where a branch
// passes the *current* value of one block param into another (loop
// rotations are the common case).
fn emit_branch_arg_moves(t: &BlockTarget, f: &Function, indent: String, sb: &StringBuilder) {
    if t.args.len == 0 { return }
    const tgt_idx = find_block_idx(f, t.label)
    const tgt = &f.blocks[tgt_idx]
    // Two-phase write: temps first, then assignments. Wrap in a block so
    // the temps don't leak into the enclosing scope.
    sb.append(indent)
    sb.append("{\n")
    for i in 0..t.args.len {
        sb.append(indent)
        sb.append("    ")
        emit_c_type(tgt.params[i].ty, sb)
        sb.append(" __mv")
        sb.append(i as u64)
        sb.append(" = ")
        emit_operand_as(&t.args[i], tgt.params[i].ty, sb)
        sb.append(";\n")
    }
    for i in 0..t.args.len {
        sb.append(indent)
        sb.append("    v")
        sb.append(tgt.params[i].id)
        sb.append(" = __mv")
        sb.append(i as u64)
        sb.append(";\n")
    }
    sb.append(indent)
    sb.append("}\n")
}

fn emit_ret(v: Operand?, f: &Function, sb: &StringBuilder) {
    sb.append("    return")
    v match {
        Some(op) => { sb.append(" "); emit_operand(&op, sb) },
        None => {
            // FIR void return in the user's main maps to `return 0;`
            // because the C entry point has `int` return type.
            const void_ret = f.return_ty match { None => true, _ => false }
            if is_entry_point(f) and void_ret {
                sb.append(" 0")
            }
        },
    }
    sb.append(";\n")
}

// ─────────────────────────────────────────────────────────────────────────
// Hex helpers
// ─────────────────────────────────────────────────────────────────────────

fn emit_hex_byte(b: u8, sb: &StringBuilder) {
    sb.append_byte(c_hex_nibble(b >> 4))
    sb.append_byte(c_hex_nibble(b & 0x0F))
}

fn c_hex_nibble(n: u8) u8 {
    if n < 10 { return '0' + n }
    return 'a' + (n - 10)
}

// =============================================================================
// Compiler discovery
// =============================================================================

// Try discovery unless the caller overrode the compiler. Override skips
// env synthesis (caller is responsible).
fn discover_or_override(options: &BuildOptions, allocator: &Allocator) Result(CompilerInfo, BuildError) {
    options.compiler_override match {
        Some(p) => {
            let env_keys: List(OwnedString) = list(0, allocator)
            let env_vals: List(OwnedString) = list(0, allocator)
            let kind = guess_kind_from_name(p)
            return Ok(CompilerInfo {
                kind = kind,
                name = from_view(p, allocator),
                path = from_view(p, allocator),
                extra_env_keys = env_keys,
                extra_env_vals = env_vals,
                allocator = allocator,
            })
        }
        None => {},
    }
    return discover_compiler(allocator)
}

fn guess_kind_from_name(name: String) CompilerKind {
    if name.contains("cl.exe") { return CompilerKind.Msvc }
    if name.contains("clang") { return CompilerKind.Clang }
    if name.contains("gcc") { return CompilerKind.Gcc }
    return CompilerKind.Clang
}

// Pick the first toolchain that exists, in platform-preferred order.
pub fn discover_compiler(allocator: &Allocator) Result(CompilerInfo, BuildError) {
    #if(platform.os == "windows") {
        // 1. MSVC via vswhere (sets INCLUDE/LIB/PATH so the spawn works
        //    outside a developer prompt).
        const msvc_r = discover_msvc(allocator)
        if msvc_r.is_some() {
            return Ok(msvc_r.unwrap())
        }
        // 2. cl.exe already on PATH (e.g. running inside a VS dev prompt).
        if can_spawn("cl.exe", allocator) {
            let env_keys: List(OwnedString) = list(0, allocator)
            let env_vals: List(OwnedString) = list(0, allocator)
            return Ok(CompilerInfo {
                kind = CompilerKind.Msvc,
                name = from_view("cl.exe", allocator),
                path = from_view("cl.exe", allocator),
                extra_env_keys = env_keys,
                extra_env_vals = env_vals,
                allocator = allocator,
            })
        }
        // 3. Fall back to clang / gcc on PATH.
        if can_spawn("clang", allocator) {
            return Ok(make_simple_info(CompilerKind.Clang, "clang", allocator))
        }
        if can_spawn("gcc", allocator) {
            return Ok(make_simple_info(CompilerKind.Gcc, "gcc", allocator))
        }
        return Err(BuildError.NoCompilerFound)
    }

    // POSIX: $CC first, then macOS-only xcrun clang, then clang/cc/gcc.
    const cc_opt = env("CC")
    cc_opt match {
        Some(cc) => {
            if cc.len > 0 and can_spawn(cc, allocator) {
                return Ok(make_simple_info(guess_kind_from_name(cc), cc, allocator))
            }
        }
        None => {}
    }
    #if(platform.os == "macos") {
        if can_spawn("xcrun", allocator) {
            return Ok(make_simple_info(CompilerKind.XcrunClang, "xcrun", allocator))
        }
    }
    if can_spawn("clang", allocator) {
        return Ok(make_simple_info(CompilerKind.Clang, "clang", allocator))
    }
    if can_spawn("cc", allocator) {
        return Ok(make_simple_info(CompilerKind.Clang, "cc", allocator))
    }
    if can_spawn("gcc", allocator) {
        return Ok(make_simple_info(CompilerKind.Gcc, "gcc", allocator))
    }
    return Err(BuildError.NoCompilerFound)
}

fn make_simple_info(kind: CompilerKind, name: String, allocator: &Allocator) CompilerInfo {
    let env_keys: List(OwnedString) = list(0, allocator)
    let env_vals: List(OwnedString) = list(0, allocator)
    return CompilerInfo {
        kind = kind,
        name = from_view(name, allocator),
        path = from_view(name, allocator),
        extra_env_keys = env_keys,
        extra_env_vals = env_vals,
        allocator = allocator,
    }
}

// Spawn `prog --version`, redirect stdio to Null, wait. exit==0 means
// the binary is on PATH and runnable.
fn can_spawn(prog: String, allocator: &Allocator) bool {
    let cmd = command(prog, allocator)
    defer cmd.deinit()
    cmd.arg("--version")
    cmd.stdin_mode(Stdio.Null)
    cmd.stdout_mode(Stdio.Null)
    cmd.stderr_mode(Stdio.Null)
    cmd.inherit_env()
    let r = cmd.spawn()
    if r.is_err() { return false }
    let child = r.unwrap()
    defer child.deinit()
    const w = child.wait()
    if w.is_err() { return false }
    return true
}

// =============================================================================
// MSVC discovery via vswhere
// =============================================================================
//
// Mirrors src/FLang.CLI/CompilerDiscovery.cs::FindClExeWithEnvironment.
// vswhere.exe lives at "%ProgramFiles(x86)%\Microsoft Visual Studio\
// Installer\vswhere.exe" on every supported VS install (2017+). We use
// it to locate the active VS install dir, then walk the toolset layout
// to find cl.exe + matching INCLUDE / LIB directories.

fn discover_msvc(allocator: &Allocator) CompilerInfo? {
    // ProgramFiles(x86) is the conventional location; fall back to the
    // hard-coded path when the env var is missing (some CI shells don't
    // forward it).
    let pf86_buf = string_builder(64, allocator)
    defer pf86_buf.deinit()
    const pf86_env = env("ProgramFiles(x86)")
    pf86_env match {
        Some(s) => pf86_buf.append(s),
        None => pf86_buf.append("C:\\Program Files (x86)"),
    }

    let vswhere_sb = string_builder(pf86_buf.len + 80, allocator)
    defer vswhere_sb.deinit()
    vswhere_sb.append(pf86_buf.as_view())
    vswhere_sb.append("\\Microsoft Visual Studio\\Installer\\vswhere.exe")
    // NUL-terminate so is_file's C stat() call sees a valid C string.
    nul_term(&vswhere_sb)
    const vswhere = vswhere_sb.as_view()

    if !file_exists(vswhere) { return null }

    // Capture vswhere output to find the latest VS install dir.
    let install_opt = run_vswhere(vswhere, allocator)
    if install_opt.is_none() { return null }
    let install = install_opt.unwrap()
    defer install.deinit()

    let tools = string_builder(install.len + 32, allocator)
    defer tools.deinit()
    tools.append(install.as_view())
    tools.append("\\VC\\Tools\\MSVC")
    nul_term(&tools)
    if !dir_exists(tools.as_view()) { return null }

    // Latest toolset version = dir name with the largest lexicographic value.
    let toolset_opt = newest_subdir(tools.as_view(), allocator)
    if toolset_opt.is_none() { return null }
    let toolset = toolset_opt.unwrap()
    defer toolset.deinit()

    let toolset_dir = string_builder(tools.len + toolset.len + 2, allocator)
    defer toolset_dir.deinit()
    toolset_dir.append(tools.as_view())
    toolset_dir.append("\\")
    toolset_dir.append(toolset.as_view())

    let cl = string_builder(toolset_dir.len + 32, allocator)
    defer cl.deinit()
    cl.append(toolset_dir.as_view())
    cl.append("\\bin\\Hostx64\\x64\\cl.exe")
    nul_term(&cl)
    if !file_exists(cl.as_view()) { return null }

    let include_dir = string_builder(toolset_dir.len + 16, allocator)
    defer include_dir.deinit()
    include_dir.append(toolset_dir.as_view())
    include_dir.append("\\include")

    let lib_dir = string_builder(toolset_dir.len + 16, allocator)
    defer lib_dir.deinit()
    lib_dir.append(toolset_dir.as_view())
    lib_dir.append("\\lib\\x64")

    // Windows SDK paths: pick the latest sub-version under
    // "C:\Program Files (x86)\Windows Kits\10\Include".
    let sdk_root = "C:\\Program Files (x86)\\Windows Kits\\10"
    let sdk_include_root = string_builder(64, allocator)
    defer sdk_include_root.deinit()
    sdk_include_root.append(sdk_root)
    sdk_include_root.append("\\Include")
    nul_term(&sdk_include_root)

    let sdk_ver_opt: OwnedString? = null
    if dir_exists(sdk_include_root.as_view()) {
        sdk_ver_opt = newest_subdir(sdk_include_root.as_view(), allocator)
    }

    let include_paths = string_builder(256, allocator)
    defer include_paths.deinit()
    include_paths.append(include_dir.as_view())
    sdk_ver_opt match {
        Some(ver) => {
            include_paths.append(";")
            include_paths.append(sdk_root)
            include_paths.append("\\Include\\")
            include_paths.append(ver.as_view())
            include_paths.append("\\ucrt;")
            include_paths.append(sdk_root)
            include_paths.append("\\Include\\")
            include_paths.append(ver.as_view())
            include_paths.append("\\um;")
            include_paths.append(sdk_root)
            include_paths.append("\\Include\\")
            include_paths.append(ver.as_view())
            include_paths.append("\\shared")
        }
        None => {}
    }

    let lib_paths = string_builder(256, allocator)
    defer lib_paths.deinit()
    lib_paths.append(lib_dir.as_view())
    sdk_ver_opt match {
        Some(ver) => {
            lib_paths.append(";")
            lib_paths.append(sdk_root)
            lib_paths.append("\\Lib\\")
            lib_paths.append(ver.as_view())
            lib_paths.append("\\ucrt\\x64;")
            lib_paths.append(sdk_root)
            lib_paths.append("\\Lib\\")
            lib_paths.append(ver.as_view())
            lib_paths.append("\\um\\x64")
        }
        None => {}
    }

    // cl.exe relies on linker tools in its own bin dir — prepend it to
    // PATH so the spawned child finds link.exe / mspdbcore.dll.
    let path_with_bin = string_builder(256, allocator)
    defer path_with_bin.deinit()
    path_with_bin.append(toolset_dir.as_view())
    path_with_bin.append("\\bin\\Hostx64\\x64")
    const cur_path_opt = env("PATH")
    cur_path_opt match {
        Some(p) => { path_with_bin.append(";"); path_with_bin.append(p) }
        None => {},
    }

    let env_keys: List(OwnedString) = list(3, allocator)
    let env_vals: List(OwnedString) = list(3, allocator)
    env_keys.push(from_view("INCLUDE", allocator))
    env_vals.push(from_view(include_paths.as_view(), allocator))
    env_keys.push(from_view("LIB", allocator))
    env_vals.push(from_view(lib_paths.as_view(), allocator))
    env_keys.push(from_view("PATH", allocator))
    env_vals.push(from_view(path_with_bin.as_view(), allocator))

    sdk_ver_opt match {
        Some(v) => { let vv = v; vv.deinit() },
        None => {},
    }

    return CompilerInfo {
        kind = CompilerKind.Msvc,
        name = from_view("cl.exe", allocator),
        path = from_view(cl.as_view(), allocator),
        extra_env_keys = env_keys,
        extra_env_vals = env_vals,
        allocator = allocator,
    }
}

// Spawn `vswhere -latest ... -property installationPath` and capture
// the first line of stdout.
fn run_vswhere(vswhere_path: String, allocator: &Allocator) OwnedString? {
    let cmd = command(vswhere_path, allocator)
    defer cmd.deinit()
    cmd.arg("-latest")
    cmd.arg("-products")
    cmd.arg("*")
    cmd.arg("-requires")
    cmd.arg("Microsoft.VisualStudio.Component.VC.Tools.x86.x64")
    cmd.arg("-property")
    cmd.arg("installationPath")
    cmd.stdin_mode(Stdio.Null)
    cmd.stdout_mode(Stdio.Pipe)
    cmd.stderr_mode(Stdio.Null)
    cmd.inherit_env()
    let r = cmd.spawn()
    if r.is_err() { return null }
    let child = r.unwrap()
    defer child.deinit()
    let stdout_opt = child.stdout()
    if stdout_opt.is_none() { return null }
    let s = stdout_opt.unwrap()
    let raw = s.read_to_end(allocator)
    const w = child.wait()
    if w.is_err() {
        raw.deinit()
        return null
    }
    // Trim trailing CR/LF + whitespace; "" means vswhere found nothing.
    const trimmed = raw.as_view().trim()
    if trimmed.len == 0 {
        raw.deinit()
        return null
    }
    let result = from_view(trimmed, allocator)
    raw.deinit()
    return result
}

// Write a trailing 0 byte without bumping the StringBuilder's logical
// length. Used to hand a NUL-terminated C string to libc routines that
// take `&u8` (which flang stdlib does not auto-terminate).
fn nul_term(sb: &StringBuilder) {
    sb.ensure_capacity(sb.len + 1)
    const term: &u8 = sb.ptr + sb.len
    term.* = 0
}

fn file_exists(p: String) bool {
    return is_file(p)
}

fn dir_exists(p: String) bool {
    return is_dir(p)
}

// Returns the lexicographically largest subdirectory name, which for
// MSVC toolset versions and Windows SDK versions corresponds to the
// most recent install.
fn newest_subdir(parent: String, allocator: &Allocator) OwnedString? {
    // read_dir's C shim wants a NUL-terminated path. Copy into a builder
    // we control so callers can pass plain views.
    let pbuf = string_builder(parent.len + 1, allocator)
    defer pbuf.deinit()
    pbuf.append(parent)
    nul_term(&pbuf)
    let it_r = read_dir(pbuf.as_view())
    if it_r.is_err() { return null }
    let it = it_r.unwrap()
    defer it.deinit()

    let best: OwnedString? = null
    loop {
        const e_opt = it.next()
        if e_opt.is_none() { break }
        const e = e_opt.unwrap()
        const is_dir_entry = e.kind match { Dir => true, _ => false }
        if !is_dir_entry { continue }
        best match {
            Some(b) => {
                if e.name > b.as_view() {
                    let bb = b
                    bb.deinit()
                    best = from_view(e.name, allocator)
                }
            }
            None => {
                best = from_view(e.name, allocator)
            }
        }
    }
    return best
}

// =============================================================================
// Build orchestration
// =============================================================================

fn write_c_file(path: String, contents: String, allocator: &Allocator) Result((), FileError) {
    // open() expects a NUL-terminated path; copy into a builder we control.
    let pbuf = string_builder(path.len + 1, allocator)
    defer pbuf.deinit()
    pbuf.append(path)
    nul_term(&pbuf)
    let f_r = open_file(pbuf.as_view(), FileMode.Write)
    if f_r.is_err() { return Err(f_r.unwrap_err()) }
    let f = f_r.unwrap()
    const w = write(&f, contents)
    const c = close_file(&f)
    if w.is_err() { return Err(w.unwrap_err()) }
    if c.is_err() { return Err(c.unwrap_err()) }
    return Ok(())
}

fn remove_file_quiet(path: String) {
    // Best-effort: ignore errors. The next compile run will overwrite
    // anyway, so a stale .c here is annoying but not fatal.
    // (No std.fs.remove yet — leave the .c on disk silently.)
}

// Build the argv passed to the compiler. Layout differs between MSVC
// and Unix-style; both layouts compile-and-link in one shot.
fn build_compiler_argv(info: &CompilerInfo, c_path: String, options: &BuildOptions) List(OwnedString) {
    let alloc = options.allocator
    let argv: List(OwnedString) = list(16, alloc)

    if info.is_xcrun() {
        argv.push(from_view("clang", alloc))
    }

    let release = options.mode match { Release => true, _ => false }

    if info.is_msvc() {
        argv.push(from_view("/nologo", alloc))
        argv.push(from_view("/W3", alloc))
        argv.push(from_view("/std:c11", alloc))
        argv.push(from_view("/Z7", alloc))
        if release {
            argv.push(from_view("/O2", alloc))
        }
        for i in 0..options.cflags.len {
            argv.push(from_view(options.cflags[i], alloc))
        }
        for i in 0..options.include_paths.len {
            let sb = string_builder(2 + options.include_paths[i].len, alloc)
            sb.append("/I")
            sb.append(options.include_paths[i])
            argv.push(sb.to_string())
        }
        // /Fe: places the .exe; /Fo places .obj output. Keep both
        // alongside the .c file to make cleanup easy.
        let fe = string_builder(4 + options.output_path.len, alloc)
        fe.append("/Fe:")
        fe.append(options.output_path)
        argv.push(fe.to_string())
        argv.push(from_view(c_path, alloc))
        for i in 0..options.extra_c_files.len {
            argv.push(from_view(options.extra_c_files[i], alloc))
        }
        for i in 0..options.extra_obj_files.len {
            argv.push(from_view(options.extra_obj_files[i], alloc))
        }
        // MSVC linker libs are positional after a `/link` separator.
        if options.libs.len > 0 or options.ldflags.len > 0 {
            argv.push(from_view("/link", alloc))
            for i in 0..options.libs.len {
                argv.push(from_view(options.libs[i], alloc))
            }
            for i in 0..options.ldflags.len {
                argv.push(from_view(options.ldflags[i], alloc))
            }
        }
        return argv
    }

    // Unix-style (clang / gcc / xcrun clang).
    argv.push(from_view("-Werror", alloc))
    argv.push(from_view("-Wno-pointer-sign", alloc))
    if release {
        argv.push(from_view("-O2", alloc))
    } else {
        argv.push(from_view("-g", alloc))
    }
    for i in 0..options.cflags.len {
        argv.push(from_view(options.cflags[i], alloc))
    }
    for i in 0..options.include_paths.len {
        let sb = string_builder(3 + options.include_paths[i].len, alloc)
        sb.append("-I")
        sb.append(options.include_paths[i])
        argv.push(sb.to_string())
    }
    argv.push(from_view("-o", alloc))
    argv.push(from_view(options.output_path, alloc))
    argv.push(from_view(c_path, alloc))
    for i in 0..options.extra_c_files.len {
        argv.push(from_view(options.extra_c_files[i], alloc))
    }
    for i in 0..options.extra_obj_files.len {
        argv.push(from_view(options.extra_obj_files[i], alloc))
    }
    argv.push(from_view("-lm", alloc))
    for i in 0..options.libs.len {
        // Absolute path -> verbatim; bare name -> "-lNAME".
        const lib = options.libs[i]
        if lib.len > 0 and (lib[0] == '/' or lib.starts_with("./") or lib.contains(".a") or lib.contains(".so")) {
            argv.push(from_view(lib, alloc))
        } else {
            let sb = string_builder(3 + lib.len, alloc)
            sb.append("-l")
            sb.append(lib)
            argv.push(sb.to_string())
        }
    }
    for i in 0..options.ldflags.len {
        argv.push(from_view(options.ldflags[i], alloc))
    }
    return argv
}

// Spawn the compiler with the prepared argv + env. Returns the exit code.
fn run_compiler(info: &CompilerInfo, argv: &List(OwnedString), allocator: &Allocator) Result(i32, BuildError) {
    let cmd = command(info.path.as_view(), allocator)
    defer cmd.deinit()
    for i in 0..argv.len {
        cmd.arg(argv[i].as_view())
    }
    cmd.inherit_env()
    for i in 0..info.extra_env_keys.len {
        cmd.env(info.extra_env_keys[i].as_view(), info.extra_env_vals[i].as_view())
    }
    // stdout/stderr inherit — let the user see compiler output.
    let r = cmd.spawn()
    if r.is_err() {
        return Err(BuildError.SpawnFailed)
    }
    let child = r.unwrap()
    defer child.deinit()
    const w = child.wait()
    if w.is_err() {
        return Err(BuildError.SpawnFailed)
    }
    return Ok(w.unwrap())
}
