// One-shot build: lower a checked unit to FIR and hand it to the C backend.
// The back half of the pipeline `flang_driver.analyze` opens.

import std.allocator
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import std.io.file
import std.io.fs
import std.time
import flang_parser.ast
import flang_parser.comptime
import flang_typer.result
import flang_codegen.fir
import flang_codegen.backend
import flang_codegen.c_backend
import flang_analysis.analyze
import flang_driver.lower
import flang_analysis.project
import flang_analysis.resolver

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
// callers check `project_error_count` first. `source_paths` is the module
// set's file list: every `.f` with a companion `.c` beside it is compiled
// and linked in, which covers both the stdlib's runtime sidecars (fs, time,
// process - without them every `#foreign __flang_*` call is an undefined
// symbol) and a project's own native shims. Same rule as the reference
// compiler (Compiler.cs step 6).
// `libs`/`ldflags` are the host platform's `[build.<os>]` entries, already
// expanded and validated by the caller (env expansion touches the
// environment, so it stays at the CLI edge).
// `release` optimizes the generated C.
// `keep_c` retains the generated C beside the executable instead of
// deleting it after the link - the input the stage-N fixpoint compares.
// `verbose` prints the skip report - one line per function lowering
// refused (directly or transitively), with the reason. TEMPORARY
// SCAFFOLD like `IrModule.skipped` itself: the frontier report for the
// self-host milestones; delete together with the skip mechanism.
pub fn build_program(modules: &List(Module), fqns: &List(OwnedString), result: &TypeCheckResult, output_path: String, comptime_ctx: ComptimeCtx, source_paths: &List(OwnedString), libs: &List(OwnedString), ldflags: &List(OwnedString), verbose: bool = false, keep_c: bool = false, release: bool = false, allocator: &Allocator? = null) Result(BuildResult, BuildError) {
    const lower_start = monotonic_ns()
    let m = lower_program(modules, fqns, result, comptime_ctx, allocator)
    const lower_ns = elapsed_ns(lower_start)
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
    let _k = opts.set_keep_temps(keep_c)
    let _r = opts.set_release(release)

    let runtime_c = companion_c_files(source_paths, allocator)
    for i in 0..runtime_c.len {
        let _o = opts.add_c_file(runtime_c[i].as_view())
    }
    // `[build.<os>]` from flang.toml: the native libraries and linker flags
    // this project needs. Already env-expanded by the CLI edge.
    for i in 0..libs.len {
        let _l = opts.add_lib(libs[i].as_view())
    }
    for i in 0..ldflags.len {
        let _f = opts.add_ldflag(ldflags[i].as_view())
    }

    let r = compile(&m, &opts)
    opts.deinit()
    m.deinit()
    runtime_c.deinit()
    if r.is_err() { return r }
    // The backend times its own phases but never sees the lowering.
    let artifact = r.unwrap()
    artifact.set_lower_ns(lower_ns)
    return Ok(artifact)
}

// Every `<mod>.c` sitting beside a `<mod>.f` in the module set. A `.c` the
// compiler itself emitted is skipped: the harness writes `<test>.c` next to
// `<test>.f`, and linking a previous build's output would duplicate every
// symbol in it.
fn companion_c_files(source_paths: &List(OwnedString), allocator: &Allocator? = null) List(OwnedString) {
    let found: List(OwnedString) = list(0, allocator)
    for i in 0..source_paths.len {
        const path = source_paths[i].as_view()
        if path.len < 2 { continue }
        if path[path.len - 2] != '.' or path[path.len - 1] != 'f' { continue }
        const c_path = $"{path[0..(path.len - 1)]}c"
        if !exists(c_path.as_view()) {
            c_path.deinit()
            continue
        }
        if is_generated_c(c_path.as_view()) {
            c_path.deinit()
            continue
        }
        found.push(c_path)
    }
    return found
}

// Both backends stamp "Generated by" into the first line of what they emit
// (`/* Generated by FLang ... */`, `/* Generated by flang_codegen.c_backend ... */`).
fn is_generated_c(path: String) bool {
    let src_opt = read_text(path)
    if src_opt.is_none() { return true }
    let src = src_opt.unwrap()
    defer src.deinit()
    const head = src.as_view()
    const limit = if head.len < 200 as usize { head.len } else { 200 as usize }
    return contains(head[0..limit], "Generated by")
}
