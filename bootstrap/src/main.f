// the FLang compiler, written in FLang.
//
//   flang [--help] [--version] [-v|--verbose] <command> [args...]
//
//   commands:
//     build <file.f>        compile a source file
//     fmt   [<file.f>...]   format the project (or the given files) in place
//     lsp                   speak LSP over stdio until the client exits
//
// fmt runs in-process on lib/flang_fmt; lsp runs in-process on lib/flang_lsp.

import std.allocator
import std.dict
import std.env
import std.list
import std.option
import std.process
import std.result
import std.set
import std.string
import std.string_builder
import std.io.file
import std.io.fs
import std.time
import flang_core.diagnostic
import flang_parser.comptime
import flang_parser.lexer
import flang_fmt.fmt
import flang_codegen.backend
import flang_analysis.analyze
import flang_driver.compile
import flang_analysis.project
import flang_analysis.resolver
import flang_typer.nominal_registry
import flang_typer.result
import flang_typer.type
import flang_typer.checker
import flang_typer.inference_engine
import flang_typer.interner
import flang_typer.specialization
import flang_typer.result_diff
import flang_lsp.server
import flang.frontend

// Parsed CLI state. `subcommand` is the first positional argument; the remainder of argv after the
// subcommand is passed through to whatever handler we dispatch to.
type Cli = struct {
    show_help: bool
    show_version: bool
    verbose: bool
    emit_generated: bool
    keep_c: bool
    emit_c_only: bool
    timings: bool
    release: bool
    profile: bool
    profile_all: bool
    check: bool
    gate_a: bool
    gate_b: bool
    eager: bool
    warn_unused: bool
    mem: bool
    subcommand: String
    rest_index: usize
    stdlib_path: String
    target_os: String
    target_arch: String
}

// Everything a build needs beyond the input path: the flags that shape it, plus the values derived
// once from the CLI (stdlib root, compile-time context) and the clock it started on.
type BuildOpts = struct {
    verbose: bool
    check_only: bool
    emit_generated: bool
    keep_c: bool
    emit_c_only: bool
    timings: bool
    release: bool
    profile: bool
    profile_all: bool
    gate_a: bool
    gate_b: bool
    eager: bool
    warn_unused: bool
    mem: bool
    stdlib_path: String
    target: ComptimeCtx
    start_ns: u64
}

pub fn main() i32 {
    let args = get_args()
    defer args.deinit()
    const argv = args.as_slice()

    let cli = parse_cli(argv)

    if cli.show_help {
        print_help()
        return 0
    }
    if cli.show_version {
        print_version()
        return 0
    }
    if cli.subcommand.len == 0 {
        print_help()
        return 1
    }

    return cli.subcommand match {
        "build" => run_build(argv, cli.rest_index, &cli)
        "fmt" => run_fmt(argv, cli.rest_index)
        "lsp" => run_lsp(argv, cli.rest_index, &cli)
        "cst" => spawn_tool("cst_explorer", argv, cli.rest_index, cli.verbose)
        "tokens" => spawn_tool("dump_tokens", argv, cli.rest_index, cli.verbose)
        else => unknown_subcommand(cli.subcommand)
    }
}

// CLI parsing

// Drive std.env.getopts over `argv[1..]`, then pick the first non-option argument as the
// subcommand. Index 0 is the program name and is skipped.
fn parse_cli(argv: String[]) Cli {
    let cli: Cli
    let opts = getopts("h(help)V(version)v(verbose)c(check)g(emit-generated)k(keep-c)E(emit-c-only)t(timings)r(release)p(profile)P(profile-all)G(gate-a)B(gate-b)e(eager)W(warn-unused)M(mem)s(stdlib-path):T(target-os):A(target-arch):",
        argv, 1)

    // Drive opts.next() manually rather than `for r in opts` - std.env's `iter(&GetOpt)` returns a
    // *copy* of the iterator state, so a for-loop's mutations don't flow back into `opts` and we
    // lose `rest_index()` after the subcommand is consumed.
    loop {
        const item = opts.next()
        if item.is_none() {
            break
        }
        item.unwrap() match {
            Opt(c) => {
                if c == 'h' {
                    cli.show_help = true
                }
                if c == 'V' {
                    cli.show_version = true
                }
                if c == 'v' {
                    cli.verbose = true
                }
                if c == 'g' {
                    cli.emit_generated = true
                }
                if c == 'k' {
                    cli.keep_c = true
                }
                if c == 'E' {
                    cli.emit_c_only = true
                }
                if c == 't' {
                    cli.timings = true
                }
                if c == 'r' {
                    cli.release = true
                }
                if c == 'p' {
                    cli.profile = true
                }
                if c == 'P' {
                    cli.profile_all = true
                }
                if c == 'c' {
                    cli.check = true
                }
                if c == 'G' {
                    cli.gate_a = true
                }
                if c == 'B' {
                    cli.gate_b = true
                }
                if c == 'e' {
                    cli.eager = true
                }
                if c == 'W' {
                    cli.warn_unused = true
                }
                if c == 'M' {
                    cli.mem = true
                }
            }
            OptArg(c, val) => {
                if c == 's' {
                    cli.stdlib_path = val
                }
                if c == 'T' {
                    cli.target_os = val
                }
                if c == 'A' {
                    cli.target_arch = val
                }
            }
            NonOpt(s) => {
                cli.subcommand = s
                cli.rest_index = opts.rest_index()
                break
            }
            Error(c) => {
                const msg = $"flang: unrecognized option `-{c}`"
                defer msg.deinit()
                println(msg.as_view())
                cli.show_help = true
                break
            }
            MissingArg(c) => {
                const msg = $"flang: option `-{c}` requires an argument"
                defer msg.deinit()
                println(msg.as_view())
                cli.show_help = true
                break
            }
            else => {}
        }
    }

    return cli
}

fn print_help() {
    const me = project_info()
    const banner = $"{me.name} {me.version} - the SELF-HOSTED compiler (written in FLang)"
    defer banner.deinit()
    println(banner.as_view())
    println("Subset of the reference CLI: no `test`, `-o` or bare-file form.")
    println("")
    println("usage: flang [options] <command> [args...]")
    println("")
    println("commands:")
    println("  build  [file.f]      build the project (flang.toml), or a single file")
    println("  fmt    [file.f...]   format the project (flang.toml), or the given files")
    println("                       --check: write nothing, exit 1 if anything would change")
    println("  lsp [-s dir]         start the language server over stdio (in-process)")
    println("  cst    <file.f>      print the CST tree (spawns cst_explorer)")
    println("  tokens <file.f>      print the token stream (spawns dump_tokens)")
    println("")
    println("options:")
    println("  -h, --help          show this help")
    println("  -V, --version       show version")
    println("  -v, --verbose       verbose output")
    println("  -g, --emit-generated  write template expansions to <origin>.generated.f (debug)")
    println("  -c, --check         type-check only (no codegen or link)")
    println("  -k, --keep-c        keep the generated C beside the executable")
    println("  -E, --emit-c-only   write the generated C and stop (no compile or link);")
    println("                      with -T/-A this emits C for an OS the host cannot link")
    println("  -t, --timings       print per-phase wall times")
    println("  -r, --release       optimize the generated C (-O2 / /O2)")
    println("  -p, --profile       instrument the project's functions for profiling (implies")
    println("                      --release); the binary prints a profile on exit, see std.profile")
    println("  -P, --profile-all   like --profile, but instrument the stdlib too")
    println("  -G, --gate-a        check the analysis against a re-analysis (RFC-022 gate A)")
    println("  -B, --gate-b        check lazy demand against total demand (RFC-022 gate B)")
    println("  -e, --eager         type-check every loaded module's bodies, not just the")
    println("                      project's import closure")
    println("  -W, --warn-unused   report unreachable project functions (W1003)")
    println("  -M, --mem           report heap bytes still out when the build ends")
    println("  -T, --target-os     target OS for #if evaluation (windows|linux|macos)")
    println("  -A, --target-arch   target arch for #if evaluation (x86_64|arm64|x86)")
    println("  -s, --stdlib-path <dir>  stdlib root (default: <exe dir>/stdlib)")
}

fn print_version() {
    const me = project_info()
    const banner = $"{me.name} {me.version} (self-hosted compiler, FLang; flang_parser {parser_version()})"
    defer banner.deinit()
    println(banner.as_view())
}

fn unknown_subcommand(name: String) i32 {
    const msg = $"flang: unknown command `{name}`"
    defer msg.deinit()
    println(msg.as_view())
    print_help()
    return 1
}

// Subcommand handlers

// build: a `<file>.f` argument compiles that single file through the same multi-module pipeline as
// project mode, so its imports and the stdlib resolve; with no argument, load `flang.toml` from the
// current directory and build the project.
fn run_build(argv: String[], rest: usize, cli: &Cli) i32 {
    const target_opt = resolve_target(cli.target_os, cli.target_arch)
    if target_opt.is_none() {
        return 1
    }
    let stdlib = effective_stdlib(cli.stdlib_path, argv)
    defer stdlib.deinit()
    const opts = BuildOpts {
        verbose = cli.verbose,
        check_only = cli.check,
        emit_generated = cli.emit_generated,
        keep_c = cli.keep_c,
        emit_c_only = cli.emit_c_only,
        timings = cli.timings,
        // Profiling a build the C compiler didn't optimize measures the debug codegen, not the
        // program - `--profile` implies `--release`.
        release = cli.release or cli.profile or cli.profile_all,
        profile = cli.profile or cli.profile_all,
        profile_all = cli.profile_all,
        gate_a = cli.gate_a,
        gate_b = cli.gate_b,
        eager = cli.eager,
        warn_unused = cli.warn_unused,
        mem = cli.mem,
        stdlib_path = stdlib.as_view(),
        target = target_opt.unwrap(),
        start_ns = monotonic_ns(),
    }
    if rest < argv.len {
        const path = argv[rest]
        if ends_with(path, ".f") {
            const out = output_path_for(path)
            return build_single_file(path, out, &opts)
        }
        const msg = $"flang: `build` takes a `.f` file or no argument (got `{path}`)"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    return build_project(&opts)
}

// The compile-time context for this build: host values, overridden by `--target-os` /
// `--target-arch`. Unknown values are hard errors - a typo'd target must never silently select
// wrong #if branches.
fn resolve_target(target_os: String, target_arch: String) ComptimeCtx? {
    if target_os.len > 0 {
        if target_os != "windows" and target_os != "linux" and target_os != "macos" {
            const m = $"flang: unknown --target-os `{target_os}` (expected windows, linux, or macos)"
            defer m.deinit()
            println(m.as_view())
            return null
        }
    }
    if target_arch.len > 0 {
        if target_arch != "x86_64" and target_arch != "arm64" {
            const m = $"flang: unknown --target-arch `{target_arch}` (expected x86_64 or arm64)"
            defer m.deinit()
            println(m.as_view())
            return null
        }
    }
    // Scoped mutability: ComptimeCtx fields are writable only in comptime.f, so build the override
    // by construction.
    const host = host_ctx()
    return Some(ComptimeCtx {
        os = if target_os.len > 0 { target_os } else { host.os },
        arch = if target_arch.len > 0 { target_arch } else { host.arch },
        testing = false,
        release = false,
    })
}

// The stdlib include root: the explicit `--stdlib-path` when given, else `<dir of argv[0]>/stdlib`,
// mirroring the reference compiler's `AppContext.BaseDirectory/stdlib` so `build` works without the
// flag (the build deploys a `stdlib` copy next to the compiler binary).
fn effective_stdlib(given: String, argv: String[]) OwnedString {
    if given.len > 0 {
        return from_view(given)
    }
    let exe = if argv.len > 0 { argv[0] } else { "" }
    let dir = dir_of(exe)
    if dir.len == 0 {
        return from_view("stdlib")
    }
    return $"{dir}/stdlib"
}

// Directory portion of a path, or "" when it has no separator. Handles both `/` and `\` since
// argv[0] carries the OS-native form.
fn dir_of(path: String) String {
    let cut: usize? = null
    let fwd = rfind(path, '/')
    if fwd.is_some() {
        cut = fwd
    }
    let back = rfind(path, '\\')
    if back.is_some() and (cut.is_none() or back.unwrap() > cut.unwrap()) {
        cut = back
    }
    return cut match {
        Some(i) => path[0..i]
        None => ""
    }
}

// Project mode: parse `flang.toml`, glob its sources, resolve imports across the whole project
// (plus the auto-imported prelude), type-check every module together, then lower the lot to one
// executable.
fn build_project(opts: &BuildOpts) i32 {
    if !exists("flang.toml") {
        println("flang: no flang.toml in the current directory")
        return 1
    }
    const toml_res = read_source("flang.toml")
    if toml_res.is_err() {
        report_read_error("flang.toml", toml_res.unwrap_err())
        return 1
    }
    let toml = toml_res.unwrap()
    defer toml.deinit()

    let proj = parse_project(toml.as_view())
    defer proj.deinit()

    let sources = glob_sources(proj.source.as_view())
    defer sources.deinit()

    if sources.len == 0 {
        const m = $"flang: no sources match `{proj.source.as_view()}`"
        defer m.deinit()
        println(m.as_view())
        return 1
    }

    let ctx = resolve_ctx(&proj, opts.stdlib_path)
    defer ctx.deinit()
    ctx.set_comptime(opts.target)
    // Lazy body demand is the default (RFC-022 §6): only the project's import closure is
    // body-checked. `--eager` restores the total demand.
    ctx.set_lazy(!opts.eager)
    ctx.set_warn_unused(opts.warn_unused)

    if opts.gate_b {
        return run_gate_b(&ctx, &sources, null)
    }

    // `--mem` routes the analysis through a counting decorator; the report at the end covers the
    // heap it was handed, not the whole process.
    let counted = counting_allocator(&global_allocator)
    let counting = counted.allocator()
    let alloc: &Allocator? = null
    if opts.mem {
        alloc = Some(&counting)
    }

    let unit = analyze_project(&ctx, &sources, null, alloc)
    defer unit.deinit()

    // Memory probe: FLANG_REDEMAND=<n> re-demands the project n times after analysis, printing
    // retention per round under --mem. FLANG_REDEMAND_CLEAN keeps the dirty set empty (only the
    // always-stale generator origins re-parse); FLANG_REDEMAND_EXIT tears the unit down and reports
    // before exiting, so live-at-exit is memory nothing owns - the leak, apart from the unit's
    // retention. See the leak entry in docs/known-issues.md.
    const probe = env("FLANG_REDEMAND")
    if probe.is_some() {
        const n = gate_index_of(probe.unwrap())
        let pd: Set(String) = set()
        defer pd.deinit()
        if env("FLANG_REDEMAND_CLEAN").is_none() and unit.file_paths.len > 0 {
            pd.add(unit.file_paths[0].as_view())
        }
        for _k in 0..n.unwrap_or(0usize) {
            reanalyze(&unit, &ctx, &pd, null, alloc)
            let rs: usize = 0
            for &s in unit.retired_sources {
                rs = rs + s.as_view().len
            }
            const dbg = $"DBG retired: {unit.retired_sources.len} sources ({rs / 1024} KB), {unit.retired_modules.len} modules, {unit.retired_results.len} results"
            println(dbg.as_view())
            dbg.deinit()
            if opts.mem {
                report_mem(&counted)
            }
        }
        if env("FLANG_REDEMAND_EXIT").is_some() {
            unit.deinit()
            report_mem(&counted)
            exit(0)
        }
    }

    if opts.gate_a {
        const code = run_gate_a(&ctx, &unit, alloc)
        if opts.mem {
            report_tables(&unit)
        }
        if opts.mem {
            report_mem(&counted)
        }
        return code
    }
    if opts.mem {
        report_tables(&unit)
    }
    if opts.mem {
        report_engine(&unit)
    }
    if opts.mem {
        report_type_sharing(&unit)
    }
    if opts.mem {
        report_mem(&counted)
    }

    // `[build.<os>]` native inputs. `${VAR}` expansion reads the environment, so it happens here at
    // the CLI edge rather than inside the driver; an undefined variable is an error, not an empty
    // string silently dropped from the link line.
    const plat = proj.current_platform()
    let missing: List(OwnedString) = list(0)
    defer missing.deinit()
    let libs = expand_all(&plat.libs, &missing)
    defer libs.deinit()
    let ldflags = expand_all(&plat.ldflags, &missing)
    defer ldflags.deinit()
    if missing.len > 0 {
        let names = string_builder(64)
        defer names.deinit()
        for i in 0..missing.len {
            if i > 0 {
                names.append(", ")
            }
            names.append("$")
            names.append(missing[i].as_view())
        }
        const m = $"flang: undefined environment variable(s): {names.as_view()}"
        defer m.deinit()
        println(m.as_view())
        return 1
    }

    const out = $"{proj.output.as_view()}/{proj.name.as_view()}"
    defer out.deinit()
    return finish_build(&unit, proj.name.as_view(), out.as_view(), opts, &libs, &ldflags)
}

// Single-file mode: the file is the sole entry of a project-less build, so its imports resolve
// against the stdlib and the working directory.
fn build_single_file(path: String, out: String, opts: &BuildOpts) i32 {
    let ctx = single_file_ctx(opts.stdlib_path)
    defer ctx.deinit()
    ctx.set_comptime(opts.target)
    ctx.set_lazy(!opts.eager)
    ctx.set_warn_unused(opts.warn_unused)

    let entries: List(OwnedString) = list(1)
    entries.push(from_view(path))
    defer entries.deinit()

    if opts.gate_b {
        return run_gate_b(&ctx, &entries, null)
    }

    let unit = analyze_project(&ctx, &entries)
    defer unit.deinit()

    if opts.gate_a {
        return run_gate_a(&ctx, &unit, null)
    }

    if opts.emit_generated {
        const n = unit.write_generated()
        if opts.verbose {
            const gm = $"  wrote {n} generated file(s)"
            defer gm.deinit()
            println(gm.as_view())
        }
    }
    // No manifest, so no `[build.<os>]` inputs.
    let none: List(OwnedString) = list(0)
    defer none.deinit()
    return finish_build(&unit, path, out, opts, &none, &none)
}

// Gate A (RFC-022): analyse the project a second time and require the two results to be identical
// table by table - nominals, specializations, node types, resolved targets, resolved operators.
//
// What that proves today is that a check is deterministic, which the harness and the stage fixpoint
// do not: both run cold and single-pass. Once per-module invalidation lands the second pass becomes
// dirty-one-module-and-re-demand, and the same comparison is what catches a stale cache entry
// surviving the invalidation.
//
// ponytail: the second pass is a full cold analysis until the query graph exists; only this
// function changes when it does. The result's own tables, largest first. Bytes are the backing
// arrays; the gap against the allocator's total is what those arrays' entries own.
fn report_tables(unit: &AnalyzedProject) {
    const rows = unit.result.table_sizes()
    defer rows.deinit()
    let counted: usize = 0
    for &r in rows {
        counted = counted + r.bytes
        if r.bytes < 1048576usize {
            continue
        }
        const line = $"mem:   {r.name} - {r.entries} entries, {r.bytes / 1048576usize} MB"
        defer line.deinit()
        println(line.as_view())
    }
    const tail = $"mem:   tables total {counted / 1048576usize} MB"
    defer tail.deinit()
    println(tail.as_view())
}

// The inference engine's own tables. Every type variable inference minted has a row in each of
// these, and `prim_constraints` holds a list per row.
fn report_engine(unit: &AnalyzedProject) {
    const e = &unit.checker.engine
    let constraint_bytes: usize = 0
    for entry in e.prim_constraints {
        constraint_bytes = constraint_bytes + entry.value.capacity_bytes()
    }
    const line = $"mem:   engine: {e.var_counter} type vars, {e.bindings.length} bindings ({e.bindings.capacity_bytes() / 1048576usize} MB), {e.prim_constraints.length} prim-constrained ({constraint_bytes / 1048576usize} MB in their lists), {e.levels.length} levels ({e.levels.capacity_bytes() / 1048576usize} MB)"
    defer line.deinit()
    println(line.as_view())
}

// Node types held against node types that differ. Each entry is a type tree of its own, so the two
// numbers separate how many trees are stored from how many shapes they are drawn from.
fn report_type_sharing(unit: &AnalyzedProject) {
    let seen: Set(String) = set()
    defer seen.deinit()
    let total: usize = 0
    for entry in unit.result.node_types {
        total = total + 1
        seen.add(unit.result.interner.key_of(entry.value))
    }
    const line = $"mem:   node types: {total} stored, {seen.len()} distinct, {unit.result.interner.len()} interned nodes"
    defer line.deinit()
    println(line.as_view())
}

// Heap the analysis has out, and what it went through to get there.
fn report_mem(c: &CountingAllocator) {
    const live = $"mem: {c.live_bytes / 1048576usize} MB live at exit, {c.peak_bytes / 1048576usize} MB peak, {c.total_bytes / 1048576usize} MB handed out in total"
    defer live.deinit()
    println(live.as_view())
    const ops = $"mem: {c.allocs} allocs, {c.reallocs} reallocs, {c.deallocs} frees"
    defer ops.deinit()
    println(ops.as_view())
}

// Plain decimal digits to a usize; null for anything else.
fn gate_index_of(s: String) usize? {
    if s.len == 0 {
        return null
    }
    let n: usize = 0
    for i in 0..s.len {
        const c = s[i]
        if c < '0' or c > '9' {
            return null
        }
        n = n * 10 + ((c as usize) - 48)
    }
    return Some(n)
}

fn run_gate_a(ctx: &ResolveCtx, cold: &AnalyzedProject, alloc: &Allocator?) i32 {
    if !cold.checked {
        println("gate A: the project does not type-check - nothing to compare")
        return 1
    }
    // Dirty a few modules and demand the project again: the reused entries have to reproduce the
    // cold result exactly. Three positions in demand order - first, middle, last - so a recycled
    // declaration is compared from below, among and above the ids of the modules that were kept.
    const before_diags = cold.diagnostics.len
    const cold_parse_ns = cold.parse_ns
    const cold_collect_ns = cold.result.phases.collect_ns
    const cold_nominals_ns = cold.result.phases.nominals_ns
    const cold_signatures_ns = cold.result.phases.signatures_ns
    const cold_bodies_ns = cold.result.phases.bodies_ns
    const cold_specialize_ns = cold.result.phases.specialize_ns
    const dirty: Set(String) = set()
    defer dirty.deinit()
    // FLANG_GATE_DIRTY names one module to dirty - by demand-order index or by path - instead of
    // the default three. The per-module sweep runs the gate once per module, one process each (each
    // demand retires the result it replaces, so one process cannot afford a hundred re-demands).
    const forced = env("FLANG_GATE_DIRTY")
    if forced.is_some() {
        const key = forced.unwrap()
        const idx = gate_index_of(key)
        if idx.is_some() and idx.unwrap() < cold.file_paths.len {
            dirty.add(cold.file_paths[idx.unwrap()].as_view())
        } else {
            dirty.add(key)
        }
    } else {
        const n = cold.file_paths.len
        if n > 0 {
            dirty.add(cold.file_paths[0].as_view())
            dirty.add(cold.file_paths[n / 2].as_view())
            dirty.add(cold.file_paths[n - 1].as_view())
        }
    }
    const before = cold.result
    // The diff below reads `before`'s tables after the re-demand, so its retirement must not slim
    // them.
    keep_retired_results(cold)
    reanalyze(cold, ctx, &dirty, null, alloc)

    let d = diff_results(&before, &cold.result)
    defer d.deinit()

    const cold_diags = before_diags
    const again_diags = cold.diagnostics.len
    if cold_diags != again_diags {
        const m = $"gate A: {cold_diags} diagnostic(s) cold, {again_diags} on re-analysis"
        defer m.deinit()
        println(m.as_view())
    }

    if d.is_empty() and cold_diags == again_diags {
        const types = &cold.result.node_types
        const specs = &cold.result.specializations
        const noms = &cold.result.nominals
        const nt: usize = types.len()
        const ns: usize = specs.len()
        const nn: usize = noms.len()
        const mods = cold.modules.len
        if nt == 0 {
            println("gate A: nothing was checked - the comparison proves nothing")
            return 1
        }
        const ok = $"gate A: OK - {mods} modules, {nt} node types, {ns} specializations, {nn} nominals identical"
        defer ok.deinit()
        println(ok.as_view())
        // The rest of the check runs in full either way, so these are what distinguish a reused
        // entry from one computed again: the first pair for the module ASTs, the second for the
        // type names collected from them.
        const cold_ms = cold_parse_ns / 1000000u64
        const warm_ms = cold.parse_ns / 1000000u64
        const p = $"gate A: parse {cold_ms} ms cold, {warm_ms} ms re-demanded"
        defer p.deinit()
        println(p.as_view())
        const cold_us = cold_collect_ns / 1000u64
        const warm_collect_us = cold.result.phases.collect_ns / 1000u64
        const c = $"gate A: collect {cold_us} us cold, {warm_collect_us} us re-demanded"
        defer c.deinit()
        println(c.as_view())
        const cold_nom_us = cold_nominals_ns / 1000u64
        const warm_nom_us = cold.result.phases.nominals_ns / 1000u64
        const b = $"gate A: nominal bodies {cold_nom_us} us cold, {warm_nom_us} us re-demanded"
        defer b.deinit()
        println(b.as_view())
        const cold_sig_us = cold_signatures_ns / 1000u64
        const warm_sig_us = cold.result.phases.signatures_ns / 1000u64
        const s = $"gate A: signatures {cold_sig_us} us cold, {warm_sig_us} us re-demanded"
        defer s.deinit()
        println(s.as_view())
        const cold_body_ms = cold_bodies_ns / 1000000u64
        const warm_body_ms = cold.result.phases.bodies_ns / 1000000u64
        const bd = $"gate A: bodies {cold_body_ms} ms cold, {warm_body_ms} ms re-demanded"
        defer bd.deinit()
        println(bd.as_view())
        const cold_spec_ms = cold_specialize_ns / 1000000u64
        const warm_spec_ms = cold.result.phases.specialize_ns / 1000000u64
        const sp = $"gate A: settle {cold_spec_ms} ms cold, {warm_spec_ms} ms re-demanded"
        defer sp.deinit()
        println(sp.as_view())
        return 0
    }

    const head = $"gate A: FAILED - {d.total} difference(s)"
    defer head.deinit()
    println(head.as_view())
    for &msg in d.messages {
        const line = $"  {msg.as_view()}"
        println(line.as_view())
        line.deinit()
    }
    const shown = d.messages.len
    if d.total > shown {
        const hidden = d.total - shown
        const rest = $"  ({hidden} more not shown)"
        defer rest.deinit()
        println(rest.as_view())
    }
    return 1
}

// Gate B (RFC-022): analyse the project twice - total demand, then lazy demand - and require the
// two published diagnostic lists to be identical. Laziness may only ever skip work whose absence is
// invisible: a module outside the demand set has no diagnostics either way, because the whole tree
// is expected to be clean.
fn run_gate_b(ctx: &ResolveCtx, entries: &List(OwnedString), alloc: &Allocator?) i32 {
    ctx.set_lazy(false)
    let eager = analyze_project(ctx, entries, null, alloc)
    defer eager.deinit()
    ctx.set_lazy(true)
    let lazy = analyze_project(ctx, entries, null, alloc)
    defer lazy.deinit()

    if !eager.checked or !lazy.checked {
        println("gate B: the project does not type-check - nothing to compare")
        return 1
    }

    let a = diag_keys(&eager.diagnostics)
    defer a.deinit()
    let b = diag_keys(&lazy.diagnostics)
    defer b.deinit()
    let diffs: usize = 0
    if a.len != b.len {
        const m = $"gate B: {a.len} diagnostic(s) eager, {b.len} lazy"
        defer m.deinit()
        println(m.as_view())
        diffs = 1
    } else {
        for i in 0..a.len {
            if a[i].as_view() == b[i].as_view() {
                continue
            }
            diffs = diffs + 1
            if diffs <= 10 {
                const m = $"  eager: {a[i].as_view()}\n  lazy:  {b[i].as_view()}"
                defer m.deinit()
                println(m.as_view())
            }
        }
    }
    if diffs > 0 {
        const m = $"gate B: FAILED - {diffs} difference(s)"
        defer m.deinit()
        println(m.as_view())
        return 1
    }

    let skipped: usize = 0
    for f in lazy.demanded {
        if !f {
            skipped = skipped + 1
        }
    }
    const ok = $"gate B: OK - {a.len} diagnostic(s) identical, {skipped} of {lazy.modules.len} module slots skipped"
    defer ok.deinit()
    println(ok.as_view())
    const eb = eager.result.phases.bodies_ns / 1000000u64
    const lb = lazy.result.phases.bodies_ns / 1000000u64
    const bd = $"gate B: bodies {eb} ms eager, {lb} ms lazy"
    defer bd.deinit()
    println(bd.as_view())
    return 0
}

// One diagnostic as a comparable line, the list sorted - publication order may differ between the
// two demands, identity must not.
fn diag_keys(diags: &List(Diagnostic)) List(OwnedString) {
    let out: List(OwnedString) = list(diags.len)
    for i in 0..diags.len {
        const d = &diags[i]
        out.push($"{d.code}|{d.span.file_id}|{d.span.start}|{d.message.as_view()}")
    }
    out.sort(cmp_owned)
    return out
}

fn cmp_owned(a: OwnedString, b: OwnedString) Ord {
    return op_cmp(a.as_view(), b.as_view())
}

// Expand `${VAR}` in each entry against the environment. An undefined variable's name is collected
// in `missing` and the entry is dropped - the caller reports them together, the way the reference
// compiler does.
fn expand_all(items: &List(OwnedString), missing: &List(OwnedString)) List(OwnedString) {
    let out: List(OwnedString) = list(items.len)
    for &item in items {
        const s = item.as_view()
        let sb = string_builder(s.len)
        let ok = true
        let i: usize = 0
        while i < s.len {
            if i + 1 < s.len and s[i] == '$' and s[i + 1] == '{' {
                let j = i + 2
                while j < s.len and s[j] != '}' { j = j + 1 }
                if j >= s.len {
                    // No closing brace - not a reference, copy verbatim.
                    sb.append(s[i..(i + 1)])
                    i = i + 1
                    continue
                }
                const key = s[(i + 2)..j]
                env(key) match {
                    Some(v) => sb.append(v)
                    None => {
                        ok = false
                        missing.push(from_view(key))
                    }
                }
                i = j + 1
            } else {
                sb.append(s[i..(i + 1)])
                i = i + 1
            }
        }
        if ok {
            out.push(sb.to_string())
        } else {
            sb.deinit()
        }
    }
    return out
}

// Shared render -> gate -> lower -> link tail for both build modes.
fn finish_build(unit: &AnalyzedProject, label: String, out: String, opts: &BuildOpts,
    libs: &List(OwnedString), ldflags: &List(OwnedString)) i32 {
    render_project_diagnostics(&unit.diagnostics, &unit.file_paths, &unit.sources)

    const errs = project_error_count(unit)
    if opts.verbose {
        const v = $"  ({unit.modules.len} modules, {unit.result.node_types.len()} nodes typed)"
        defer v.deinit()
        println(v.as_view())
    }
    if errs > 0 {
        return build_failed(label, errs)
    }

    if opts.check_only {
        const m = $"checked {label} ({unit.modules.len} modules) in {elapsed_ns(opts.start_ns) / 1000000}ms"
        defer m.deinit()
        println(m.as_view())
        if opts.timings {
            print_timings(unit, 0, 0, 0, elapsed_ns(opts.start_ns))
        }
        return 0
    }

    let dm: &List(bool)? = null
    if unit.demanded.len > 0 {
        dm = Some(&unit.demanded)
    }
    const prof_c = if opts.profile { $"{opts.stdlib_path}/std/profile.c" } else { from_view("") }
    defer prof_c.deinit()
    let prof_rt: String? = null
    if opts.profile {
        prof_rt = Some(prof_c.as_view())
    }
    let result = build_program(&unit.modules, &unit.fqns, &unit.result, out, opts.target,
        &unit.file_paths, libs, ldflags, opts.verbose, opts.keep_c, opts.release, dm, prof_rt,
        opts.profile_all, opts.emit_c_only)
    if result.is_err() {
        report_build_error(&result.unwrap_err(), label)
        return 1
    }
    let artifact = result.unwrap()
    defer artifact.deinit()
    const built = if opts.emit_c_only {
        (artifact.c_source_path ?? artifact.executable_path).as_view()
    } else {
        artifact.executable_path.as_view()
    }
    const verb = if opts.emit_c_only { "emitted" } else { "built" }
    const msg = $"{verb} {built} in {elapsed_ns(opts.start_ns) / 1000000}ms"
    defer msg.deinit()
    println(msg.as_view())
    if opts.timings {
        print_timings(unit, artifact.lower_ns, artifact.translate_ns, artifact.cc_ns,
            elapsed_ns(opts.start_ns))
    }
    return 0
}

// `--timings`: where the wall time went, one line per phase, with the typechecker broken into its
// own phases beneath it. "other" is the remainder - project manifest, glob, diagnostics rendering,
// teardown - and is the cue that a phase worth naming is still unaccounted for.
fn print_timings(unit: &AnalyzedProject, lower_ns: u64, translate_ns: u64, cc_ns: u64,
    total_ns: u64) {
    const p = unit.result.phases
    println("timings:")
    print_phase("read + parse", unit.parse_ns, total_ns, false)
    print_phase("typecheck", unit.check_ns, total_ns, false)
    print_phase("visibility", p.visibility_ns, total_ns, true)
    print_phase("collect", p.collect_ns, total_ns, true)
    print_phase("templates", p.templates_ns, total_ns, true)
    print_phase("nominals", p.nominals_ns, total_ns, true)
    print_phase("signatures", p.signatures_ns, total_ns, true)
    print_phase("constants", p.constants_ns, total_ns, true)
    print_phase("bodies", p.bodies_ns, total_ns, true)
    print_phase("specialize", p.specialize_ns, total_ns, true)
    print_phase("zonk", p.zonk_ns, total_ns, true)
    print_phase("lower", lower_ns, total_ns, false)
    print_phase("emit C", translate_ns, total_ns, false)
    print_phase("cc + link", cc_ns, total_ns, false)
    const named = unit.parse_ns + unit.check_ns + lower_ns + translate_ns + cc_ns
    print_phase("other", if named < total_ns { total_ns - named } else { 0 as u64 }, total_ns,
        false)
    print_phase("total", total_ns, total_ns, false)
}

fn print_phase(label: String, ns: u64, total_ns: u64, nested: bool) {
    const pct = if total_ns > 0 { (ns * 100) / total_ns } else { 0 as u64 }
    let pad = string_builder(24)
    defer pad.deinit()
    pad.append(if nested { "    " } else { "  " })
    pad.append(label)
    while pad.len < 20 { pad.append(" ") }
    const line = $"{pad.as_view()} {ns / 1000000} ms ({pct}%)"
    defer line.deinit()
    println(line.as_view())
}

// Derive the output artifact path from the input: strip a trailing `.f` so `hello.f` builds to
// `hello` (the backend adds any platform suffix).
fn output_path_for(path: String) String {
    if path.len >= 2 {
        if path[path.len - 2] == '.' and path[path.len - 1] == 'f' {
            return path[0..(path.len - 2)]
        }
    }
    return path
}

// The CLI edge renders IO failures; `read_source` itself stays pure.
fn report_read_error(path: String, e: FileError) {
    const label = e match {
        NotFound => "not found"
        PermissionDenied => "permission denied"
        NameTooLong => "path too long"
        AlreadyExists => "already exists"
        InvalidArgument => "invalid path"
        IOError => "read failed"
    }
    const m = $"flang: cannot read `{path}`: {label}"
    defer m.deinit()
    println(m.as_view())
}

fn report_build_error(e: &BuildError, path: String) {
    const label = e.* match {
        NoCompilerFound => "no C compiler found"
        CompilerFailed(_) => "the C compiler returned an error"
        SpawnFailed => "could not spawn the C compiler"
        IOError => "I/O error while writing build artifacts"
        LowerFailed => "IR lowering rejected the module"
    }
    const m = $"build failed: {label} ({path})"
    defer m.deinit()
    println(m.as_view())
}

fn build_failed(path: String, errs: usize) i32 {
    const m = $"build failed: {errs} error(s) in {path}"
    defer m.deinit()
    println(m.as_view())
    return 1
}

// fmt subcommand

// lsp: serve the language server over stdio until the client sends `exit`. The stdlib root comes
// from `-s` in either position (`flang -s <p> lsp` or `flang lsp -s <p>`), defaulting to the `<exe
// dir>/stdlib` convention like `build`.
fn run_lsp(argv: String[], rest: usize, cli: &Cli) i32 {
    let stdlib = effective_stdlib(cli.stdlib_path, argv)
    let opts = getopts("s(stdlib-path):", argv, rest)
    loop {
        const item = opts.next()
        if item.is_none() {
            break
        }
        item.unwrap() match {
            OptArg(c, val) => {
                if c == 's' {
                    stdlib.deinit()
                    stdlib = from_view(val)
                }
            }
            else => {}
        }
    }
    defer stdlib.deinit()

    // Content-Length framing is byte-exact; Windows text-mode stdio would corrupt it.
    const _ib = set_binary_mode(&stdin)
    const _ob = set_binary_mode(&stdout)

    const me = project_info()
    let srv = lsp_server(stdin.reader(), stdout.writer(), stdlib.as_view(), me.version, true)
    defer srv.deinit()
    return srv.run()
}

type FmtStatus = enum {
    Unchanged
    Changed
    Failed
}

// fmt: format the given files in place, or with no arguments every source matched by the project's
// `flang.toml` glob. A `[fmt]` table in the manifest tunes the style. `--check` writes nothing and
// exits 1 when any file would change.
fn run_fmt(argv: String[], rest: usize) i32 {
    let check = false
    let files: List(String) = list(0)
    defer files.deinit()
    for i in rest..argv.len {
        if argv[i] == "--check" {
            check = true
        } else {
            files.push(argv[i])
        }
    }

    let cfg = default_config()
    let sources: List(OwnedString) = list(0)
    defer sources.deinit()

    const have_manifest = exists("flang.toml")
    if !have_manifest and files.len == 0 {
        println("flang: fmt needs file arguments or a flang.toml project")
        return 1
    }
    if have_manifest {
        const toml_res = read_source("flang.toml")
        if toml_res.is_err() {
            report_read_error("flang.toml", toml_res.unwrap_err())
            return 1
        }
        let toml = toml_res.unwrap()
        defer toml.deinit()
        let proj = parse_project(toml.as_view())
        defer proj.deinit()
        for &e in proj.fmt {
            if !set_option(&cfg, e.key.as_view(), e.value.as_view()) {
                const w = $"flang: ignoring unknown [fmt] entry `{e.key.as_view()} = {e.value.as_view()}`"
                defer w.deinit()
                println(w.as_view())
            }
        }
        if files.len == 0 {
            sources = glob_sources(proj.source.as_view())
        }
    }
    for f in files {
        sources.push(from_view(f))
    }

    if sources.len == 0 {
        println("flang: nothing to format")
        return 1
    }

    let changed: usize = 0
    let failed: usize = 0
    for &s in sources {
        fmt_file(s.as_view(), &cfg, check) match {
            Unchanged => {}
            Changed => { changed = changed + 1 }
            Failed => { failed = failed + 1 }
        }
    }

    if check and changed > 0 {
        const m = $"flang: {changed} file(s) would be reformatted"
        defer m.deinit()
        println(m.as_view())
    }
    if !check and changed > 0 {
        const m = $"formatted {changed} of {sources.len} file(s)"
        defer m.deinit()
        println(m.as_view())
    }
    if failed > 0 {
        return 1
    }
    if check and changed > 0 {
        return 1
    }
    return 0
}

// Format one file in place. In check mode nothing is written; a file that would change reports
// itself.
fn fmt_file(path: String, cfg: &FmtConfig, check: bool) FmtStatus {
    const read_res = read_source(path)
    if read_res.is_err() {
        report_read_error(path, read_res.unwrap_err())
        return FmtStatus.Failed
    }
    let source = read_res.unwrap()
    defer source.deinit()

    const fmt_res = format_source(source.as_view(), cfg)
    if fmt_res.is_err() {
        report_fmt_error(path, fmt_res.unwrap_err())
        return FmtStatus.Failed
    }
    let formatted = fmt_res.unwrap()
    defer formatted.deinit()

    if formatted.as_view() == source.as_view() {
        return FmtStatus.Unchanged
    }
    if check {
        const m = $"would reformat {path}"
        defer m.deinit()
        println(m.as_view())
        return FmtStatus.Changed
    }
    const wr = open_file(path, FileMode.Write)
    let wrote = false
    if !wr.is_err() {
        let handle = wr.unwrap()
        wrote = !write(&handle, formatted.as_view()).is_err()
        close_file(&handle)
    }
    if !wrote {
        const m = $"flang: cannot write `{path}`"
        defer m.deinit()
        println(m.as_view())
        return FmtStatus.Failed
    }
    return FmtStatus.Changed
}

fn report_fmt_error(path: String, e: FmtError) {
    const msg = e match {
        ParseFailed(n) => $"flang: `{path}` has {n} parse error(s) - not formatted"
        VerifyFailed => $"flang: formatter verification failed on `{path}` (formatter bug) - file left untouched"
    }
    defer msg.deinit()
    println(msg.as_view())
}

// Spawn the sibling tool with our trailing argv. Tool binaries are expected on PATH (or addressable
// by relative name); the child inherits our environment so it sees the same workspace context.
fn spawn_tool(tool: String, argv: String[], rest: usize, verbose: bool) i32 {
    if verbose {
        const v = $"flang: spawning `{tool}`"
        defer v.deinit()
        println(v.as_view())
    }

    let cmd = command(tool)
    defer cmd.deinit()
    cmd.inherit_env()
    for i in rest..argv.len {
        cmd.arg(argv[i])
    }

    const spawn_result = cmd.spawn()
    if spawn_result.is_err() {
        const msg = $"flang: failed to spawn `{tool}` - is it on PATH?"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    let child = spawn_result.unwrap()
    defer child.deinit()

    const wait_result = child.wait()
    if wait_result.is_err() {
        const msg = $"flang: `{tool}` wait failed"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    return wait_result.unwrap()
}
