// One-shot build: lower a checked unit to FIR and hand it to the C backend.
// The back half of the pipeline `flang_driver.analyze` opens.

import std.allocator
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import flang_parser.ast
import flang_parser.comptime
import flang_typer.result
import flang_codegen.fir
import flang_codegen.backend
import flang_codegen.c_backend
import flang_driver.driver
import flang_driver.lower
import flang_driver.project

// Lower `unit` to FIR and compile+link it to an executable at
// `output_path` (the backend appends a platform extension if missing).
// The unit must be error-free - callers check `error_count` first; a unit
// that failed to type-check has no usable types to lower.
pub fn build_unit(unit: &AnalyzedUnit, output_path: String, allocator: &Allocator? = null) Result(BuildResult, BuildError) {
    let m = lower_module(&unit.module, &unit.result, allocator)
    let opts = build_options(output_path, allocator)
    let r = compile(&m, &opts)
    opts.deinit()
    m.deinit()
    return r
}

// Lower a checked multi-module project to one FIR program and compile+link
// it to an executable at `output_path`. The project must be error-free -
// callers check `project_error_count` first. When `stdlib_root` is given,
// the stdlib's C runtime sidecars (`**/*.c`: fs, time, process, ...) are
// compiled and linked in, matching what the reference compiler links -
// without them every `#foreign __flang_*` call is an undefined symbol.
// `verbose` prints the skip report - one line per function lowering
// refused (directly or transitively), with the reason. TEMPORARY
// SCAFFOLD like `IrModule.skipped` itself: the frontier report for the
// self-host milestones; delete together with the skip mechanism.
pub fn build_program(modules: &List(Module), fqns: &List(OwnedString), result: &TypeCheckResult, output_path: String, comptime_ctx: ComptimeCtx, stdlib_root: String = "", verbose: bool = false, allocator: &Allocator? = null) Result(BuildResult, BuildError) {
    let m = lower_program(modules, fqns, result, comptime_ctx, allocator)
    if verbose and m.skip_notes.len > 0 {
        const hdr = $"  {m.functions.len} function(s) emitted, {m.skip_notes.len} skipped:"
        defer hdr.deinit()
        println(hdr.as_view())
        for i in 0..m.skip_notes.len {
            const line = $"    {m.skip_notes[i].as_view()}"
            defer line.deinit()
            println(line.as_view())
        }
    }
    let opts = build_options(output_path, allocator)

    let runtime_c: List(OwnedString) = list(0, allocator)
    if stdlib_root.len > 0 {
        const pattern = $"{stdlib_root}/**/*.c"
        runtime_c = glob_sources(pattern.as_view(), allocator)
        pattern.deinit()
        for i in 0..runtime_c.len {
            let _o = opts.add_c_file(runtime_c[i].as_view())
        }
    }

    let r = compile(&m, &opts)
    opts.deinit()
    m.deinit()
    runtime_c.deinit()
    return r
}
