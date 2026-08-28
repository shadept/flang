// the FLang compiler, written in FLang.
//
//   flang [--help] [--version] [-v|--verbose] <command> [args...]
//
//   commands:
//     build <file.f>        compile a source file
//     test  [path] [--name] build the project's `test {}` blocks and run them
//     check                 type-check the project, test blocks included
//     fmt   [<file.f>...]   format the project (or the given files) in place
//     lsp                   speak LSP over stdio until the client exits
//
// fmt runs in-process on lib/flang_fmt; lsp runs in-process on lib/flang_lsp.

import std.dict
import std.env
import std.list
import std.option
import std.path
import std.process
import std.result
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
import flang_typer.result
import flang_typer.type
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
    eager: bool
    warn_unused: bool
    subcommand: String
    // `test --name <substr>`.
    name_filter: String
    // Positional arguments after the subcommand, in order, with every option and option-argument
    // already removed.
    args: List(String)
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
    eager: bool
    warn_unused: bool
    // `flang test`: build the project's `test {}` blocks into a runner and execute it, instead of
    // building the program. `test_path` keeps only the blocks in files whose path contains it and
    // `test_name` only those whose label contains it; both empty means every block. The filters
    // apply at lowering, so what is in the binary is exactly what will run - and the module set is
    // the whole project either way, so filtering can never change what compiles.
    testing: bool
    test_path: String
    test_name: String
    // Owned, not a view: it outlives whatever `--stdlib-path` pointed at and is what every consumer
    // here reads through.
    stdlib_path: OwnedString
    target: ComptimeCtx
    start_ns: u64
}

pub fn deinit(self: &BuildOpts) {
    self.stdlib_path.deinit()
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

    const code = cli.subcommand match {
        "build" => run_build(argv, &cli)
        "test" => run_test(argv, &cli)
        "check" => run_check(argv, &cli)
        "fmt" => run_fmt(&cli)
        "lsp" => run_lsp(argv, &cli)
        "cst" => spawn_tool("cst_explorer", &cli)
        "tokens" => spawn_tool("dump_tokens", &cli)
        else => unknown_subcommand(cli.subcommand)
    }
    cli.args.deinit()
    return code
}

// CLI parsing

// `flang <command> [options] [args]`. The subcommand is argv[1]; everything after it is parsed by
// one `getopts` over that slice, with a format built from the options every command shares plus the
// ones this command adds. Options therefore belong to the command they follow, which is what lets
// `test` have `-n` while `build` has `-p` without either having to know about the other.
//
// `flang --help` / `--version` with no command are the only forms where an option leads.
fn parse_cli(argv: String[]) Cli {
    let cli: Cli
    cli.args = list(0)
    if argv.len < 2 {
        cli.show_help = true
        return cli
    }

    const head = argv[1]
    if starts_with(head, "-") {
        // No command: only the shared options are meaningful, and any of them but `--version` ends
        // in the same place - the help text.
        if head == "-V" or head == "--version" {
            cli.show_version = true
            return cli
        }
        if !(head == "-h" or head == "--help") {
            const msg = $"flang: `{head}` must follow a command"
            defer msg.deinit()
            println(msg.as_view())
        }
        cli.show_help = true
        return cli
    }

    cli.subcommand = head
    const spec = $"{SHARED_OPTS}{command_opts(head)}"
    defer spec.deinit()
    apply_opts(&cli, spec.as_view(), argv)
    return cli
}

// Options accepted after any command. Kept apart from the per-command sets so a new command starts
// with these and adds only what it needs.
const SHARED_OPTS: String = "h(help)V(version)v(verbose)s(stdlib-path):T(target-os):A(target-arch):"

// What each command accepts on top of `SHARED_OPTS`. An unknown command gets none, and is reported
// as unknown before the options matter.
fn command_opts(cmd: String) String {
    return cmd match {
        "build" => "c(check)g(emit-generated)k(keep-c)E(emit-c-only)t(timings)r(release)p(profile)P(profile-all)e(eager)W(warn-unused)"
        "test" => "n(name):r(release)k(keep-c)t(timings)e(eager)W(warn-unused)"
        "check" => "e(eager)W(warn-unused)t(timings)"
        "fmt" => "c(check)"
        else => ""
    }
}

// Drive `getopts` over `argv[2..]` and record what it finds. Positionals collect in `cli.args`; an
// unrecognized option is reported against the command that did not accept it.
fn apply_opts(cli: &Cli, spec: String, argv: String[]) {
    let opts = getopts(spec, argv, 2)
    for item in opts {
        item match {
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
                if c == 'e' {
                    cli.eager = true
                }
                if c == 'W' {
                    cli.warn_unused = true
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
                if c == 'n' {
                    cli.name_filter = val
                }
            }
            NonOpt(a) => cli.args.push(a)
            Error(c) => {
                const msg = $"flang: `{cli.subcommand}` does not accept option `-{c as char}`"
                defer msg.deinit()
                println(msg.as_view())
                cli.show_help = true
                return
            }
            MissingArg(c) => {
                const msg = $"flang: option `-{c as char}` requires an argument"
                defer msg.deinit()
                println(msg.as_view())
                cli.show_help = true
                return
            }
            else => {}
        }
    }
}

fn print_help() {
    const me = project_info()
    const banner = $"{me.name} {me.version} - the SELF-HOSTED compiler (written in FLang)"
    defer banner.deinit()
    println(banner.as_view())
    println("A reimplementation of the reference CLI, not a port: no `-o` or bare-file form, and")
    println("options are parsed against the command they follow.")
    println("")
    println("usage: flang <command> [options] [args...]")
    println("")
    println("commands:")
    println("  build  [file.f]      build the project (flang.toml), or a single file")
    println("  test   [path]        build the project's `test {}` blocks and run them")
    println("                       path: only blocks in files whose path contains it")
    println("                       --name, -n <substr>: only blocks whose label contains it")
    println("  check  [file.f]      type-check the project (or a single file), `test {}` bodies")
    println("                       included, and stop")
    println("  fmt    [file.f...]   format the project (flang.toml), or the given files")
    println("                       --check: write nothing, exit 1 if anything would change")
    println("  lsp [-s dir]         start the language server over stdio (in-process)")
    println("  cst    <file.f>      print the CST tree (spawns cst_explorer)")
    println("  tokens <file.f>      print the token stream (spawns dump_tokens)")
    println("")
    println("options (after the command; each command takes the shared set plus its own):")
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
    println("  -e, --eager         type-check every loaded module's bodies, not just the")
    println("                      project's import closure")
    println("  -W, --warn-unused   report unreachable project functions (W1003)")
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
fn run_build(argv: String[], cli: &Cli) i32 {
    let opts_opt = build_opts(argv, cli, false, false)
    if opts_opt.is_none() {
        return 1
    }
    const opts = opts_opt.unwrap()
    defer opts.deinit()
    if cli.args.len > 0 {
        const path = cli.args[0]
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

// check: type-check the project, `test {}` bodies included, and stop. `--eager` widens the check
// from the project's import closure to every module that loaded.
fn run_check(argv: String[], cli: &Cli) i32 {
    let opts_opt = build_opts(argv, cli, true, true)
    if opts_opt.is_none() {
        return 1
    }
    const opts = opts_opt.unwrap()
    defer opts.deinit()
    if cli.args.len > 0 {
        const path = cli.args[0]
        if ends_with(path, ".f") {
            return build_single_file(path, output_path_for(path), &opts)
        }
        const msg = $"flang: `check` takes a `.f` file or no argument (got `{path}`)"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    return build_project(&opts)
}

// test: build the project's `test {}` blocks into a runner and execute it.
fn run_test(argv: String[], cli: &Cli) i32 {
    if cli.args.len > 1 {
        const msg = $"flang: `test` takes at most one path filter (got {cli.args.len})"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    let opts_opt = build_opts(argv, cli, false, true)
    if opts_opt.is_none() {
        return 1
    }
    const opts = opts_opt.unwrap()
    defer opts.deinit()
    return build_project(&opts)
}

// The options every subcommand shares, assembled from the parsed CLI. Null when `--target-os` or
// `--target-arch` names something that does not exist.
fn build_opts(argv: String[], cli: &Cli, force_check: bool, testing: bool) BuildOpts? {
    const target_opt = resolve_target(cli.target_os, cli.target_arch, testing)
    if target_opt.is_none() {
        return null
    }
    let stdlib = effective_stdlib(cli.stdlib_path, argv)
    const opts = BuildOpts {
        verbose = cli.verbose,
        check_only = cli.check or force_check,
        emit_generated = cli.emit_generated,
        keep_c = cli.keep_c,
        emit_c_only = cli.emit_c_only,
        timings = cli.timings,
        // Profiling a build the C compiler didn't optimize measures the debug codegen, not the
        // program - `--profile` implies `--release`.
        release = cli.release or cli.profile or cli.profile_all,
        profile = cli.profile or cli.profile_all,
        profile_all = cli.profile_all,
        eager = cli.eager,
        warn_unused = cli.warn_unused,
        testing = testing,
        // `test`'s filters: the lone positional narrows by path, `--name` by label.
        test_path = if testing and cli.args.len > 0 { cli.args[0] } else { "" },
        test_name = if testing { cli.name_filter } else { "" },
        stdlib_path = stdlib,
        target = target_opt.unwrap(),
        start_ns = monotonic_ns(),
    }
    return Some(opts)
}

// The compile-time context for this build: host values, overridden by `--target-os` /
// `--target-arch`. Unknown values are hard errors - a typo'd target must never silently select
// wrong #if branches.
fn resolve_target(target_os: String, target_arch: String, testing: bool = false) ComptimeCtx? {
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
        testing = testing,
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

    let ctx = resolve_ctx(&proj, opts.stdlib_path.as_view())
    defer ctx.deinit()
    ctx.set_comptime(opts.target)
    // Lazy body demand is the default (RFC-022 §6): only the project's import closure is
    // body-checked. `--eager` restores the total demand.
    ctx.set_lazy(!opts.eager)
    ctx.set_warn_unused(opts.warn_unused)
    ctx.set_check_tests(opts.testing)

    let unit = analyze_project(&ctx, &sources)
    defer unit.deinit()

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

    // The runner gets its own artifact name so a `flang test` never overwrites the program, and so
    // the two keep separate build caches.
    const suffix = if opts.testing { "-test" } else { "" }
    const out = $"{proj.output.as_view()}/{proj.name.as_view()}{suffix}"
    defer out.deinit()
    return finish_build(&unit, proj.name.as_view(), out.as_view(), opts, &libs, &ldflags)
}

// Single-file mode: the file is the sole entry of a project-less build, so its imports resolve
// against the stdlib and the working directory.
fn build_single_file(path: String, out: String, opts: &BuildOpts) i32 {
    let ctx = single_file_ctx(opts.stdlib_path.as_view())
    defer ctx.deinit()
    ctx.set_comptime(opts.target)
    ctx.set_lazy(!opts.eager)
    ctx.set_warn_unused(opts.warn_unused)
    ctx.set_check_tests(opts.testing)

    let entries: List(OwnedString) = list(1)
    entries.push(from_view(path))
    defer entries.deinit()

    let unit = analyze_project(&ctx, &entries)
    defer unit.deinit()

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
    const prof_c = if opts.profile { $"{opts.stdlib_path.as_view()}/std/profile.c" } else { from_view("") }
    defer prof_c.deinit()
    let prof_rt: String? = null
    if opts.profile {
        prof_rt = Some(prof_c.as_view())
    }
    // Which modules contribute `test {}` blocks: the project's own, narrowed by the path filter. A
    // null list is an ordinary build. Non-project modules are excluded whatever the filter says - a
    // dependency's tests belong to a run launched from that dependency.
    let tm: List(bool) = list(0)
    defer tm.deinit()
    let tests: &List(bool)? = null
    if opts.testing {
        for i in 0..unit.modules.len {
            const own = i < unit.project_origin.len and unit.project_origin[i]
            const hit = opts.test_path.len == 0 or (i < unit.file_paths.len
                and contains(unit.file_paths[i].as_view(), opts.test_path))
            tm.push(own and hit)
        }
        tests = Some(&tm)
    }
    let name_filter: String? = null
    if opts.testing and opts.test_name.len > 0 {
        name_filter = Some(opts.test_name)
    }

    let result = build_program(&unit.modules, &unit.fqns, &unit.result, out, opts.target,
        &unit.file_paths, libs, ldflags, opts.verbose, opts.keep_c, opts.release, dm, prof_rt,
        opts.profile_all, opts.emit_c_only, tests, name_filter)
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
    if opts.testing and !opts.emit_c_only {
        if opts.timings {
            print_timings(unit, artifact.lower_ns, artifact.translate_ns, artifact.cc_ns,
                elapsed_ns(opts.start_ns))
        }
        return run_test_binary(built)
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

// Run the built test runner and hand back its exit code, which is 0 exactly when no test failed.
// Stdio is inherited, so the runner's per-test lines reach the terminal as they happen rather than
// arriving in one block at the end, and the environment is inherited because a test may read it.
fn run_test_binary(built: String) i32 {
    // Spawned by absolute, native-separator path. `CreateProcess` is handed the command line with
    // no explicit application name, so a relative path spelled with `/` is not reliably resolved.
    let rel = path(built)
    defer rel.deinit()
    const abs_r = to_absolute(&rel)
    if abs_r.is_err() {
        const msg = $"flang: cannot resolve the test runner's path `{built}`"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    let abs = abs_r.unwrap()
    defer abs.deinit()
    const path = abs.as_view()

    let cmd = command(path)
    defer cmd.deinit()
    let _e = cmd.inherit_env()
    const child = cmd.spawn()
    if child.is_err() {
        const msg = $"flang: could not run the test runner `{path}`"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    let proc = child.unwrap()
    defer proc.deinit()
    const code = proc.wait()
    if code.is_err() {
        println("flang: the test runner did not exit cleanly")
        return 1
    }
    return code.unwrap()
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
fn run_lsp(argv: String[], cli: &Cli) i32 {
    let stdlib = effective_stdlib(cli.stdlib_path, argv)
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
fn run_fmt(cli: &Cli) i32 {
    const check = cli.check
    let files: List(String) = list(0)
    defer files.deinit()
    for a in cli.args {
        files.push(a)
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
fn spawn_tool(tool: String, cli: &Cli) i32 {
    const verbose = cli.verbose
    if verbose {
        const v = $"flang: spawning `{tool}`"
        defer v.deinit()
        println(v.as_view())
    }

    let cmd = command(tool)
    defer cmd.deinit()
    cmd.inherit_env()
    for a in cli.args {
        cmd.arg(a)
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
