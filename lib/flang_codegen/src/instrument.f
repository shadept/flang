// Profiling instrumentation (RFC-025). Gives every FIR function a dense id, inserts
// `__flang_prof_enter(id)` at its entry and `__flang_prof_exit()` before every return, and hands
// the runtime (stdlib/std/profile.c) a name table so reports print function names.
//
// Runs after every other FIR transform: the passes before it (e.g. the shim inliner) must see the
// uninstrumented module, so an instrumented build makes the same optimization decisions as a plain
// one. A function some pass erased by inlining is gone before ids are assigned - its cost lands in
// the caller, which is where it actually runs. A function that still exists at this point is
// instrumented, `#inline`-annotated or not: the profile reports the calls that actually happen.
//
// `main` additionally gets `__flang_prof_register(count, names, names_len)` as its first
// instruction, ahead of its own enter probe and the const-init calls, so the runtime is live before
// any probe fires.

import std.allocator
import std.dict
import std.list
import std.string
import std.string_builder
import flang_codegen.fir

const PROF_ENTER = "__flang_prof_enter"
const PROF_EXIT = "__flang_prof_exit"
const PROF_REGISTER = "__flang_prof_register"
// Data-segment global holding every function name, newline-separated, in id order.
const PROF_NAMES = "__flang_prof_names"

// Instrument the functions in `m` - the whole program when `all`, otherwise the application only:
// stdlib functions (and their const-init helpers) keep no probes, so their cost bills to the
// calling application function's self time, the same way a foreign call does. Names in the table
// are the module's display names where one exists (`module.path.name(&Type,u32)`), the raw symbol
// otherwise. Returns the buffer backing the name-table global; the caller keeps it alive until the
// backend has consumed `m`, then deinits it.
pub fn instrument_profile(m: &IrModule, all: bool = false,
    allocator: &Allocator? = null) OwnedString {
    let names = string_builder(m.functions.len * 24, allocator)
    let count: usize = 0
    for i in 0..m.functions.len {
        let f = &m.functions[i]
        if !all and is_stdlib_symbol(f.name) {
            continue
        }
        m.displays.get(f.name) match {
            Some(d) => names.append(d.as_view())
            None => names.append(f.name)
        }
        names.append('\n')
        instrument_fn(f, count, allocator)
        count = count + 1
    }
    let blob = names.to_string()
    names.deinit()

    for i in 0..m.functions.len {
        let f = &m.functions[i]
        if f.name == "main" {
            let entry = &f.blocks[0]
            entry.instrs.insert(0, register_call(count, blob.as_view().len, allocator))
        }
    }

    m.add_global(Global {
        name = PROF_NAMES,
        size = blob.as_view().len as u64,
        align = 1,
        init_bytes = Some(as_raw_bytes(blob.as_view())),
    })
    add_runtime_foreigns(m, allocator)
    return blob
}

// Whether a symbol belongs to the stdlib: its module path mangles to a `std__`/`core__` prefix, and
// a stdlib const-init helper wraps that in `__finit_`.
fn is_stdlib_symbol(name: String) bool {
    return starts_with(name, "std__") or starts_with(name, "core__") or starts_with(name,
        "__finit_std__") or starts_with(name, "__finit_core__")
}

// Enter at the top of the entry block, exit at the bottom of every block that returns. A block
// ending in `Br`/`BrIf` stays inside the function; `Unreachable` never comes back, so neither needs
// a probe.
fn instrument_fn(f: &Function, id: usize, allocator: &Allocator?) {
    if f.blocks.len == 0 {
        return
    }
    let entry = &f.blocks[0]
    entry.instrs.insert(0, probe_call(PROF_ENTER, Some(id), allocator))

    for bi in 0..f.blocks.len {
        let b = &f.blocks[bi]
        const returns = b.terminator match {
            Ret(_) => true
            _ => false
        }
        if returns {
            b.instrs.push(probe_call(PROF_EXIT, null, allocator))
        }
    }
}

// A void call to `callee`, with the function id as sole argument when given.
fn probe_call(callee: String, id: usize?, allocator: &Allocator?) Instr {
    let args: List(Operand) = list(1, allocator)
    id match {
        Some(v) => args.push(Operand.IntConst(v as i64))
        None => {}
    }
    let variadic: List(IrType) = list(0, allocator)
    return Instr.Call(CallInstr {
        result = null,
        result_ty = null,
        callee = callee,
        args = args,
        variadic_arg_types = variadic,
    })
}

fn register_call(count: usize, names_len: usize, allocator: &Allocator?) Instr {
    let args: List(Operand) = list(3, allocator)
    args.push(Operand.IntConst(count as i64))
    args.push(Operand.GlobalRef(PROF_NAMES))
    args.push(Operand.IntConst(names_len as i64))
    let variadic: List(IrType) = list(0, allocator)
    return Instr.Call(CallInstr {
        result = null,
        result_ty = null,
        callee = PROF_REGISTER,
        args = args,
        variadic_arg_types = variadic,
    })
}

// Extern prototypes for the three runtime entry points, resolved against stdlib/std/profile.c at
// link time.
fn add_runtime_foreigns(m: &IrModule, allocator: &Allocator?) {
    let enter_params: List(IrType) = list(1, allocator)
    enter_params.push(IrType.I32)
    m.add_foreign(ForeignDecl {
        name = PROF_ENTER,
        return_ty = null,
        param_types = enter_params,
        variadic = false,
        cc = CallConv.C,
    })

    let exit_params: List(IrType) = list(0, allocator)
    m.add_foreign(ForeignDecl {
        name = PROF_EXIT,
        return_ty = null,
        param_types = exit_params,
        variadic = false,
        cc = CallConv.C,
    })

    let register_params: List(IrType) = list(3, allocator)
    register_params.push(IrType.I64)
    register_params.push(IrType.Ptr)
    register_params.push(IrType.I64)
    m.add_foreign(ForeignDecl {
        name = PROF_REGISTER,
        return_ty = null,
        param_types = register_params,
        variadic = false,
        cc = CallConv.C,
    })
}
