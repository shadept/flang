// codegen_demo — exercises the full codegen pipeline end-to-end.
//
//   1. Hand-build a small FIR module (calls `puts`, prints a few sums).
//   2. Lower it to C via flang_codegen.c_backend.translate.
//   3. Discover a C toolchain (MSVC / clang / gcc / xcrun) and compile.
//   4. Spawn the produced executable.
//
// On success the program prints the demo banner, three precomputed sums
// (so we know FIR control flow lowers correctly), and exits 0.

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

pub fn main() i32 {
    println("codegen_demo: building FIR module …")
    let m = build_demo_module()
    defer m.deinit()

    // Show the FIR text so the user can sanity-check what we're lowering.
    let fir_sb = string_builder(1024)
    defer fir_sb.deinit()
    print(&m, &fir_sb)
    println("")
    println("----- FIR -----")
    println(fir_sb.as_view())

    let out_path = pick_output_path()
    defer out_path.deinit()

    let opts = build_options(out_path.as_view())
    defer opts.deinit()
    opts.set_keep_temps(true)        // leave the .c next to the .exe for inspection

    println("codegen_demo: lowering + invoking C compiler …")
    let r = compile(&m, &opts)
    if r.is_err() {
        const err = r.unwrap_err()
        report_error(err)
        return 1
    }
    let result = r.unwrap()
    defer result.deinit()

    const banner = $"codegen_demo: built {result.executable_path.as_view()}"
    defer banner.deinit()
    println(banner.as_view())
    result.c_source_path match {
        Some(p) => {
            const c_banner = $"codegen_demo: kept C source at {p.as_view()}"
            defer c_banner.deinit()
            const _u = println(c_banner.as_view())
        }
        None => {}
    }

    println("codegen_demo: running …")
    println("----- program output -----")
    // Windows won't search cwd for executables — prefix with ".\\" so
    // the OS treats it as a relative path and looks where we wrote it.
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
        println("codegen_demo: failed to spawn produced executable")
        return 2
    }
    let child = s.unwrap()
    defer child.deinit()
    const w = child.wait()
    if w.is_err() {
        println("codegen_demo: wait on produced executable failed")
        return 3
    }
    const code = w.unwrap()
    const final = $"codegen_demo: program exited with code {code}"
    defer final.deinit()
    println(final.as_view())
    return 0
}

// -------------------------------------------------------------------------
// Pick "<cwd>/codegen_demo.exe" (or no extension on POSIX) as the target.
// -------------------------------------------------------------------------

fn pick_output_path() OwnedString {
    // Drop the artifact in build/ alongside the demo binary so the
    // project root stays clean (and so `flang build` already gitignores
    // it via the [project].output setting).
    let exe_name: String = "build/codegen_demo_artifact"
    #if(platform.os == "windows") {
        exe_name = "build\\codegen_demo_artifact.exe"
    }
    return from_view(exe_name)
}

// -------------------------------------------------------------------------
// Build the demo module.
//
//   foreign fn puts(s: ptr) -> i32
//
//   global @hello[14] = "Hello, FIR!\n\0"
//   global @sum_fmt[24] = "sum_to_10 = %d\n\0\0..."
//
//   fn sum_to(n: i32) -> i32 {
//     entry:
//       br loop(0, 0)
//     loop(i: i32, acc: i32):
//       %d: i8 = icmp.sge i, n
//       br_if %d, exit(acc), step(i, acc)
//     step(i: i32, acc: i32):
//       %i1: i32 = iadd i, 1
//       %a1: i32 = iadd acc, i
//       br loop(%i1, %a1)
//     exit(r: i32):
//       ret r
//   }
//
//   fn main() -> i32 {
//     entry:
//       call @puts(@hello)
//       %s10:  i32 = call @sum_to(10)
//       %s100: i32 = call @sum_to(100)
//       %m:    i32 = imul %s10, %s100
//       (print s10, s100, product via printf — see build_main)
//       ret 0
//   }
// -------------------------------------------------------------------------

fn build_demo_module() IrModule {
    let m = module()

    // foreign fn puts(s: ptr) -> i32
    let puts_params: List(IrType) = list(1)
    puts_params.push(IrType.Ptr)
    let puts_ret: IrType? = IrType.I32
    m.add_foreign(ForeignDecl {
        name = "puts",
        return_ty = puts_ret,
        param_types = puts_params,
        variadic = false,
        cc = CallConv.C,
    })

    // foreign fn printf(fmt: ptr, ...) -> i32  (variadic)
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

    // Runtime helpers wired up in the C backend's preamble. Declaring
    // them as foreigns here proves the backend skips re-emitting them.
    let argc_params: List(IrType) = list(0)
    let argc_ret: IrType? = IrType.I32
    m.add_foreign(ForeignDecl {
        name = "__flang_get_argc",
        return_ty = argc_ret,
        param_types = argc_params,
        variadic = false,
        cc = CallConv.C,
    })
    let getarg_params: List(IrType) = list(1)
    getarg_params.push(IrType.I32)
    let getarg_ret: IrType? = IrType.Ptr
    m.add_foreign(ForeignDecl {
        name = "__flang_get_arg",
        return_ty = getarg_ret,
        param_types = getarg_params,
        variadic = false,
        cc = CallConv.C,
    })

    // Banner string (NUL-terminated for puts).
    const hello: String = "Hello from FLang FIR!\0"
    m.add_global(Global {
        name = "hello",
        size = hello.len as u64,
        align = 1u64,
        init_bytes = hello.as_raw_bytes(),
    })

    // printf format string: "sum_to(%d) = %d\n\0"
    const sum_fmt: String = "sum_to(%d) = %d\n\0"
    m.add_global(Global {
        name = "sum_fmt",
        size = sum_fmt.len as u64,
        align = 1u64,
        init_bytes = sum_fmt.as_raw_bytes(),
    })

    // product format string: "product = %d\n\0"
    const prod_fmt: String = "product   = %d\n\0"
    m.add_global(Global {
        name = "prod_fmt",
        size = prod_fmt.len as u64,
        align = 1u64,
        init_bytes = prod_fmt.as_raw_bytes(),
    })

    // argv format strings — used to prove the runtime captures argv.
    const argc_fmt: String = "argc      = %d\n\0"
    m.add_global(Global {
        name = "argc_fmt",
        size = argc_fmt.len as u64,
        align = 1u64,
        init_bytes = argc_fmt.as_raw_bytes(),
    })
    const argv0_fmt: String = "argv[0]   = %s\n\0"
    m.add_global(Global {
        name = "argv0_fmt",
        size = argv0_fmt.len as u64,
        align = 1u64,
        init_bytes = argv0_fmt.as_raw_bytes(),
    })

    m.add_function(build_sum_to())
    m.add_function(build_main())
    return m
}

// fn sum_to(n: i32) -> i32 { let i = 0; let acc = 0; while i < n { acc += i; i++ }; ret acc }
fn build_sum_to() Function {
    let fb = function("sum_to", IrType.I32)
    const n = fb.param(IrType.I32)
    let entry = fb.entry()
    let loop_blk = fb.block("loop_head", IrType.I32, IrType.I32)
    let step = fb.block("loop_step", IrType.I32, IrType.I32)
    let exit_blk = fb.block("loop_exit", IrType.I32)

    // entry -> loop(0, 0)
    let entry_args: List(Operand) = list(2)
    entry_args.push(int(0))
    entry_args.push(int(0))
    entry.br_args("loop_head", entry_args)

    // loop_head(i, acc): if i >= n goto exit(acc) else step(i, acc)
    const i = loop_blk.param(0)
    const acc = loop_blk.param(1)
    const done = loop_blk.icmp_sge(IrType.I32, i, n)
    let then_args: List(Operand) = list(1)
    then_args.push(acc)
    let else_args: List(Operand) = list(2)
    else_args.push(i)
    else_args.push(acc)
    loop_blk.br_if_args(done, "loop_exit", then_args, "loop_step", else_args)

    // step(i, acc): i1 = i+1; a1 = acc+i; loop(i1, a1)
    const si = step.param(0)
    const sa = step.param(1)
    const i1 = step.iadd(IrType.I32, si, int(1))
    const a1 = step.iadd(IrType.I32, sa, si)
    let back: List(Operand) = list(2)
    back.push(i1)
    back.push(a1)
    step.br_args("loop_head", back)

    // exit(r): ret r
    const r = exit_blk.param(0)
    exit_blk.ret(r)

    return fb.finish()
}

// fn main() -> i32 {
//     puts(@hello)
//     s10  = sum_to(10)
//     s100 = sum_to(100)
//     printf(@sum_fmt, 10,  s10)
//     printf(@sum_fmt, 100, s100)
//     printf(@prod_fmt, s10 * s100)
//     ret 0
// }
fn build_main() Function {
    let fb = function("main", IrType.I32)
    let entry = fb.entry()

    entry.call_one("puts", IrType.I32, global("hello"))

    const s10 = entry.call_one("sum_to", IrType.I32, int(10))
    const s100 = entry.call_one("sum_to", IrType.I32, int(100))

    // printf(@sum_fmt, 10, s10) — variadic with explicit arg types.
    let sum_fixed_a: List(Operand) = list(1)
    sum_fixed_a.push(global("sum_fmt"))
    let sum_extras_a: List((IrType, Operand)) = list(2)
    sum_extras_a.push((IrType.I32, int(10)))
    sum_extras_a.push((IrType.I32, s10))
    entry.call_variadic("printf", IrType.I32, sum_fixed_a, sum_extras_a)

    let sum_fixed_b: List(Operand) = list(1)
    sum_fixed_b.push(global("sum_fmt"))
    let sum_extras_b: List((IrType, Operand)) = list(2)
    sum_extras_b.push((IrType.I32, int(100)))
    sum_extras_b.push((IrType.I32, s100))
    entry.call_variadic("printf", IrType.I32, sum_fixed_b, sum_extras_b)

    const prod = entry.imul(IrType.I32, s10, s100)
    let prod_fixed: List(Operand) = list(1)
    prod_fixed.push(global("prod_fmt"))
    let prod_extras: List((IrType, Operand)) = list(1)
    prod_extras.push((IrType.I32, prod))
    entry.call_variadic("printf", IrType.I32, prod_fixed, prod_extras)

    // Prove the runtime captured argv. We call the same helpers std.env
    // calls under the hood — the values come from the globals populated
    // by the wrapper main the C backend emits.
    let argc_args: List(Operand) = list(0)
    const argc = entry.call("__flang_get_argc", IrType.I32, argc_args)
    let argc_fixed: List(Operand) = list(1)
    argc_fixed.push(global("argc_fmt"))
    let argc_extras: List((IrType, Operand)) = list(1)
    argc_extras.push((IrType.I32, argc))
    entry.call_variadic("printf", IrType.I32, argc_fixed, argc_extras)

    const argv0 = entry.call_one("__flang_get_arg", IrType.Ptr, int(0))
    let argv0_fixed: List(Operand) = list(1)
    argv0_fixed.push(global("argv0_fmt"))
    let argv0_extras: List((IrType, Operand)) = list(1)
    argv0_extras.push((IrType.Ptr, argv0))
    entry.call_variadic("printf", IrType.I32, argv0_fixed, argv0_extras)

    entry.ret(int(0))
    return fb.finish()
}

// -------------------------------------------------------------------------
// Error reporting
// -------------------------------------------------------------------------

fn report_error(e: BuildError) {
    e match {
        NoCompilerFound => println("codegen_demo: no C compiler found on this system."),
        CompilerFailed(code) => {
            const msg = $"codegen_demo: C compiler exited with code {code}"
            defer msg.deinit()
            println(msg.as_view())
        },
        SpawnFailed => println("codegen_demo: failed to spawn the C compiler."),
        IOError => println("codegen_demo: I/O error writing the generated .c file."),
        LowerFailed => println("codegen_demo: FIR -> C lowering failed."),
    }
}
