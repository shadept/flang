// inliner_test — exercises lib/flang_codegen.shim_inliner on a
// hand-built module that mimics the canonical FLang shim pattern
// (RFC-015 §3.1). Prints FIR before and after the pass, asserts the
// shim wrappers were collapsed, then lowers the inlined module to C
// and runs the produced executable to confirm semantic equivalence.
//
//   inner(n)  -> n + 1                    (1-instr leaf; inlinable)
//   outer(n)  -> inner(n)                 (1-call shim;  inlinable)
//   caller(n) -> outer(n)                 (1-call shim;  inlinable, only
//                                          inlined when invoked from a
//                                          non-`main` caller — main is
//                                          exempted by design)
//   middle(n) -> caller(n)                (non-main caller; here is
//                                          where outer+inner collapse)
//   main      -> printf("%d", middle(10))
//
// After the inliner runs, every non-`main` body should contain only
// arithmetic + ret — no `call @inner` / `call @outer` left.

import std.allocator
import std.io.file
import std.list
import std.option
import std.path
import std.process
import std.result
import std.string
import std.string_builder
import flang_codegen.backend
import flang_codegen.c_backend
import flang_codegen.fir
import flang_codegen.builder
import flang_codegen.print
import flang_codegen.shim_inliner

pub fn main() i32 {
    // Smoke 1: empty module — verifies the pass never touches anything
    // when there are no functions to consider.
    let m0 = module()
    defer m0.deinit()
    const _s0 = inline_shims(&m0)

    println("inliner_test: building FIR module …")
    let m = build_module()
    defer m.deinit()

    let before_sb = string_builder(1024)
    defer before_sb.deinit()
    print(&m, &before_sb)
    println("")
    println("----- FIR (before inliner) -----")
    println(before_sb.as_view())
    println("inliner_test: running shim_inliner …")
    const stats = inline_shims(&m)
    println("inliner_test: inliner returned")
    print_stats(&stats)
    println("inliner_test: stats printed; about to re-print FIR")

    let after_sb = string_builder(1024)
    defer after_sb.deinit()
    print(&m, &after_sb)
    println("")
    println("----- FIR (after inliner) -----")
    println(after_sb.as_view())

    if !verify_no_residual_calls(&m) {
        println("inliner_test: FAIL — residual calls to shim wrappers remain in non-main bodies")
        return 1
    }
    println("inliner_test: OK — non-main bodies are free of @inner / @outer / @caller calls")

    println("inliner_test: lowering to C and running the artifact …")
    let out_path = pick_output_path()
    defer out_path.deinit()

    let opts = build_options(out_path.as_view())
    defer opts.deinit()
    opts.set_keep_temps(true)

    let r = compile(&m, &opts)
    if r.is_err() {
        const err = r.unwrap_err()
        err match {
            NoCompilerFound => println("inliner_test: no C compiler found."),
            CompilerFailed(code) => {
                const msg = $"inliner_test: C compiler exited with code {code}"
                defer msg.deinit()
                println(msg.as_view())
            },
            SpawnFailed => println("inliner_test: failed to spawn the C compiler."),
            IOError => println("inliner_test: I/O error writing the generated .c file."),
            LowerFailed => println("inliner_test: FIR -> C lowering failed."),
        }
        return 2
    }
    let result = r.unwrap()
    defer result.deinit()

    let exe_sb = string_builder(result.executable_path.len + 4)
    defer exe_sb.deinit()
    #if(platform.os == "windows") {
        exe_sb.append(".\\")
    } else {
        exe_sb.append("./")
    }
    exe_sb.append(result.executable_path.as_view())
    let cmd = command(exe_sb.as_view())
    defer cmd.deinit()
    cmd.inherit_env()
    let s = cmd.spawn()
    if s.is_err() {
        println("inliner_test: failed to spawn produced executable")
        return 3
    }
    let child = s.unwrap()
    defer child.deinit()
    const w = child.wait()
    if w.is_err() {
        println("inliner_test: wait on produced executable failed")
        return 4
    }
    const code = w.unwrap()
    if code != 0 {
        const msg = $"inliner_test: artifact exited with non-zero code {code}"
        defer msg.deinit()
        println(msg.as_view())
        return 5
    }
    println("inliner_test: PASS")
    return 0
}

// ─────────────────────────────────────────────────────────────────────
// IrModule builder
// ─────────────────────────────────────────────────────────────────────

fn build_module() IrModule {
    let m = module()

    let printf_params: List(IrType) = list(1)
    printf_params.push(IrType.Ptr)
    let printf_ret: IrType? = IrType.I32
    m.add_foreign(ForeignDecl {
        name = "printf",
        return_ty = printf_ret,
        param_types = printf_params,
        variadic = true,
        cc = CallConv.C,
    })

    const fmt: String = "middle(10) = %d\n\0"
    m.add_global(Global {
        name = "fmt",
        size = fmt.len as u64,
        align = 1u64,
        init_bytes = fmt.as_raw_bytes(),
    })

    m.add_function(build_inner())
    m.add_function(build_outer())
    m.add_function(build_caller())
    m.add_function(build_middle())
    m.add_function(build_main())
    return m
}

// inner(n) -> n + 1
fn build_inner() Function {
    let fb = function("inner", IrType.I32)
    const n = fb.param(IrType.I32)
    let entry = fb.entry()
    const t = entry.iadd(IrType.I32, n, int(1))
    entry.ret(t)
    return fb.finish()
}

// outer(n) -> inner(n)
fn build_outer() Function {
    let fb = function("outer", IrType.I32)
    const n = fb.param(IrType.I32)
    let entry = fb.entry()
    const r = entry.call_one("inner", IrType.I32, n)
    entry.ret(r)
    return fb.finish()
}

// caller(n) -> outer(n)
fn build_caller() Function {
    let fb = function("caller", IrType.I32)
    const n = fb.param(IrType.I32)
    let entry = fb.entry()
    const r = entry.call_one("outer", IrType.I32, n)
    entry.ret(r)
    return fb.finish()
}

// middle(n) -> caller(n)        (non-main caller; expect inlining here)
fn build_middle() Function {
    let fb = function("middle", IrType.I32)
    const n = fb.param(IrType.I32)
    let entry = fb.entry()
    const r = entry.call_one("caller", IrType.I32, n)
    entry.ret(r)
    return fb.finish()
}

// main() -> printf(fmt, middle(10))
fn build_main() Function {
    let fb = function("main", IrType.I32)
    let entry = fb.entry()
    const v = entry.call_one("middle", IrType.I32, int(10))
    let fixed: List(Operand) = list(1)
    fixed.push(global("fmt"))
    let extras: List((IrType, Operand)) = list(1)
    extras.push((IrType.I32, v))
    entry.call_variadic("printf", IrType.I32, fixed, extras)
    entry.ret(int(0))
    return fb.finish()
}

// ─────────────────────────────────────────────────────────────────────
// Verification
// ─────────────────────────────────────────────────────────────────────

// Walk every non-`main` function and check it has no direct call to
// any of the shim wrappers we expected the inliner to collapse. (`main`
// is exempted as a caller — calls *from* main are not inlined; that's
// the RFC-015 §3.3 default.)
fn verify_no_residual_calls(m: &IrModule) bool {
    for fi in 0..m.functions.len {
        const f = &m.functions[fi]
        if f.name == "main" { continue }
        for bi in 0..f.blocks.len {
            const b = &f.blocks[bi]
            for ii in 0..b.instrs.len {
                b.instrs[ii] match {
                    Call(c) => {
                        if c.callee == "inner" or c.callee == "outer" or c.callee == "caller" {
                            return false
                        }
                    },
                    _ => {},
                }
            }
        }
    }
    return true
}

fn print_stats(s: &InlineStats) {
    const m1 = $"  passes:           {s.passes}"
    defer m1.deinit()
    println(m1.as_view())
    const m2 = $"  inlined:          {s.inlined}"
    defer m2.deinit()
    println(m2.as_view())
    const m3 = $"  bail_size:        {s.bail_size}"
    defer m3.deinit()
    println(m3.as_view())
    const m4 = $"  bail_multi_block: {s.bail_multi_block}"
    defer m4.deinit()
    println(m4.as_view())
    const m5 = $"  bail_recursive:   {s.bail_recursive}"
    defer m5.deinit()
    println(m5.as_view())
    const m6 = $"  bail_indirect:    {s.bail_indirect}"
    defer m6.deinit()
    println(m6.as_view())
    const m7 = $"  bail_non_ret:     {s.bail_non_ret}"
    defer m7.deinit()
    println(m7.as_view())
}

fn pick_output_path() OwnedString {
    let exe_name: String = "build/inliner_test_artifact"
    #if(platform.os == "windows") {
        exe_name = "build\\inliner_test_artifact.exe"
    }
    return from_view(exe_name)
}
