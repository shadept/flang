// the FLang compiler, written in FLang.
//
//   flang [--help] [--version] [-v|--verbose] <command> [args...]
//
//   commands:
//     build <file.f>        compile a source file
//     fmt   <file.f>...     format files via tools/flang_fmt
//     lsp                   start the language server via tools/flang_lsp
//
// The fmt/lsp subcommands shell out to sibling tool binaries via
// std.process - they're separate projects that also depend on
// flang_parser + flang_core.

import std.dict
import std.env
import std.list
import std.option
import std.process
import std.result
import std.string
import std.string_builder
import std.io.file
import std.io.fs
import flang_parser.comptime
import flang_parser.lexer
import flang_codegen.backend
import flang_driver.driver
import flang_driver.compile
import flang_driver.project
import flang_driver.resolver
import flang.frontend

// Parsed CLI state. `subcommand` is the first positional argument; the
// remainder of argv after the subcommand is passed through to whatever
// handler we dispatch to.
type Cli = struct {
    show_help: bool
    show_version: bool
    verbose: bool
    emit_generated: bool
    check: bool
    subcommand: String
    rest_index: usize
    stdlib_path: String
    target_os: String
    target_arch: String
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
        "build" => run_build(argv, cli.rest_index, cli.verbose, cli.stdlib_path, cli.check, cli.target_os, cli.target_arch, cli.emit_generated)
        "fmt" => spawn_tool("flang_fmt", argv, cli.rest_index, cli.verbose)
        "lsp" => spawn_tool("flang_lsp", argv, cli.rest_index, cli.verbose)
        "cst" => spawn_tool("cst_explorer", argv, cli.rest_index, cli.verbose)
        "tokens" => spawn_tool("dump_tokens", argv, cli.rest_index, cli.verbose)
        else => unknown_subcommand(cli.subcommand)
    }
}

// CLI parsing

// Drive std.env.getopts over `argv[1..]`, then pick the first non-option
// argument as the subcommand. Index 0 is the program name and is skipped.
fn parse_cli(argv: String[]) Cli {
    let cli: Cli
    let opts = getopts("h(help)V(version)v(verbose)c(check)g(emit-generated)s(stdlib-path):T(target-os):A(target-arch):", argv, 1)

    // Drive opts.next() manually rather than `for r in opts` - std.env's
    // `iter(&GetOpt)` returns a *copy* of the iterator state, so a
    // for-loop's mutations don't flow back into `opts` and we lose
    // `rest_index()` after the subcommand is consumed.
    loop {
        const item = opts.next()
        if item.is_none() { break }
        item.unwrap() match {
            Opt(c) => {
                if c == 'h' { cli.show_help = true }
                if c == 'V' { cli.show_version = true }
                if c == 'v' { cli.verbose = true }
                if c == 'g' { cli.emit_generated = true }
                if c == 'c' { cli.check = true }
            }
            OptArg(c, val) => {
                if c == 's' { cli.stdlib_path = val }
                if c == 'T' { cli.target_os = val }
                if c == 'A' { cli.target_arch = val }
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
    println("Subset of the reference CLI: no `test`, `-o`, `--release` or bare-file form.")
    println("")
    println("usage: flang [options] <command> [args...]")
    println("")
    println("commands:")
    println("  build  [file.f]      build the project (flang.toml), or a single file")
    println("  fmt    <file.f>...   format source files (spawns flang_fmt)")
    println("  lsp                  start the language server (spawns flang_lsp)")
    println("  cst    <file.f>      print the CST tree (spawns cst_explorer)")
    println("  tokens <file.f>      print the token stream (spawns dump_tokens)")
    println("")
    println("options:")
    println("  -h, --help          show this help")
    println("  -V, --version       show version")
    println("  -v, --verbose       verbose output")
    println("  -g, --emit-generated  write template expansions to <origin>.generated.f (debug)")
    println("  -c, --check         type-check only (no codegen or link)")
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

// build: a `<file>.f` argument compiles that single file through the same
// multi-module pipeline as project mode, so its imports and the stdlib
// resolve; with no argument, load `flang.toml` from the current directory
// and build the project.
fn run_build(argv: String[], rest: usize, verbose: bool, stdlib_path: String, check_only: bool, target_os: String, target_arch: String, emit_generated: bool) i32 {
    const target_opt = resolve_target(target_os, target_arch)
    if target_opt.is_none() { return 1 }
    const target = target_opt.unwrap()
    let stdlib = effective_stdlib(stdlib_path, argv)
    defer stdlib.deinit()
    if rest < argv.len {
        const path = argv[rest]
        if ends_with(path, ".f") {
            const out = output_path_for(path)
            return build_single_file(path, out, verbose, stdlib.as_view(), check_only, target, emit_generated)
        }
        const msg = $"flang: `build` takes a `.f` file or no argument (got `{path}`)"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    return build_project(verbose, stdlib.as_view(), check_only, target, emit_generated)
}

// The compile-time context for this build: host values, overridden by
// `--target-os` / `--target-arch`. Unknown values are hard errors - a
// typo'd target must never silently select wrong #if branches.
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
    // Scoped mutability: ComptimeCtx fields are writable only in
    // comptime.f, so build the override by construction.
    const host = host_ctx()
    return Some(ComptimeCtx {
        os = if target_os.len > 0 { target_os } else { host.os },
        arch = if target_arch.len > 0 { target_arch } else { host.arch },
        testing = false,
        release = false,
    })
}

// The stdlib include root: the explicit `--stdlib-path` when given, else
// `<dir of argv[0]>/stdlib`, mirroring the reference compiler's
// `AppContext.BaseDirectory/stdlib` so `build` works without the flag (the
// build deploys a `stdlib` copy next to the compiler binary).
fn effective_stdlib(given: String, argv: String[]) OwnedString {
    if given.len > 0 { return from_view(given) }
    let exe = if argv.len > 0 { argv[0] } else { "" }
    let dir = dir_of(exe)
    if dir.len == 0 { return from_view("stdlib") }
    return $"{dir}/stdlib"
}

// Directory portion of a path, or "" when it has no separator. Handles both
// `/` and `\` since argv[0] carries the OS-native form.
fn dir_of(path: String) String {
    let cut: usize? = null
    let fwd = rfind(path, '/')
    if fwd.is_some() { cut = fwd }
    let back = rfind(path, '\\')
    if back.is_some() and (cut.is_none() or back.unwrap() > cut.unwrap()) { cut = back }
    return cut match {
        Some(i) => path[0..i],
        None => "",
    }
}

// Project mode: parse `flang.toml`, glob its sources, resolve imports
// across the whole project (plus the auto-imported prelude), type-check
// every module together, then lower the lot to one executable.
fn build_project(verbose: bool, stdlib_path: String, check_only: bool, target: ComptimeCtx, emit_generated: bool) i32 {
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
    defer deinit_source_list(&sources)

    if sources.len == 0 {
        const m = $"flang: no sources match `{proj.source.as_view()}`"
        defer m.deinit()
        println(m.as_view())
        return 1
    }

    let ctx = resolve_ctx(&proj, stdlib_path)
    defer ctx.deinit()
    ctx.set_comptime(target)

    let unit = analyze_project(&ctx, &sources)
    defer unit.deinit()

    // `[build.<os>]` native inputs. `${VAR}` expansion reads the
    // environment, so it happens here at the CLI edge rather than inside
    // the driver; an undefined variable is an error, not an empty string
    // silently dropped from the link line.
    const plat = proj.current_platform()
    let missing: List(OwnedString) = list(0)
    defer deinit_source_list(&missing)
    let libs = expand_all(&plat.libs, &missing)
    defer deinit_source_list(&libs)
    let ldflags = expand_all(&plat.ldflags, &missing)
    defer deinit_source_list(&ldflags)
    if missing.len > 0 {
        let names = string_builder(64)
        defer names.deinit()
        for i in 0..missing.len {
            if i > 0 { names.append(", ") }
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
    return finish_build(&unit, proj.name.as_view(), out.as_view(), verbose, check_only, stdlib_path, target, &libs, &ldflags)
}

// Single-file mode: the file is the sole entry of a project-less build, so
// its imports resolve against the stdlib and the working directory.
fn build_single_file(path: String, out: String, verbose: bool, stdlib_path: String, check_only: bool, target: ComptimeCtx, emit_generated: bool) i32 {
    let ctx = single_file_ctx(stdlib_path)
    defer ctx.deinit()
    ctx.set_comptime(target)

    let entries: List(OwnedString) = list(1)
    entries.push(from_view(path))
    defer deinit_source_list(&entries)

    let unit = analyze_project(&ctx, &entries)
    defer unit.deinit()

    if emit_generated {
        const n = unit.write_generated()
        if verbose { const gm = $"  wrote {n} generated file(s)"; defer gm.deinit(); println(gm.as_view()) }
    }
    // No manifest, so no `[build.<os>]` inputs.
    let none: List(OwnedString) = list(0)
    defer none.deinit()
    return finish_build(&unit, path, out, verbose, check_only, stdlib_path, target, &none, &none)
}

// Expand `${VAR}` in each entry against the environment. An undefined
// variable's name is collected in `missing` and the entry is dropped - the
// caller reports them together, the way the reference compiler does.
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
                    Some(v) => sb.append(v),
                    None => {
                        ok = false
                        missing.push(from_view(key))
                    },
                }
                i = j + 1
            } else {
                sb.append(s[i..(i + 1)])
                i = i + 1
            }
        }
        if ok { out.push(sb.to_string()) } else { sb.deinit() }
    }
    return out
}

// Shared render -> gate -> lower -> link tail for both build modes.
fn finish_build(unit: &AnalyzedProject, label: String, out: String, verbose: bool, check_only: bool, stdlib_path: String, target: ComptimeCtx, libs: &List(OwnedString), ldflags: &List(OwnedString)) i32 {
    render_project_diagnostics(&unit.diagnostics, &unit.file_paths, &unit.sources)

    const errs = project_error_count(unit)
    if verbose {
        const v = $"  ({unit.modules.len} modules, {unit.result.node_types.len()} nodes typed)"
        defer v.deinit()
        println(v.as_view())
    }
    if errs > 0 {
        return build_failed(label, errs)
    }

    if check_only {
        const m = $"checked {label} ({unit.modules.len} modules)"
        defer m.deinit()
        println(m.as_view())
        return 0
    }

    let result = build_program(&unit.modules, &unit.fqns, &unit.result, out, target, &unit.file_paths, libs, ldflags, verbose)
    if result.is_err() {
        report_build_error(&result.unwrap_err(), label)
        return 1
    }
    let artifact = result.unwrap()
    defer artifact.deinit()
    const msg = $"built {artifact.executable_path.as_view()}"
    defer msg.deinit()
    println(msg.as_view())
    return 0
}

// Derive the output artifact path from the input: strip a trailing `.f`
// so `hello.f` builds to `hello` (the backend adds any platform suffix).
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
        NotFound => "not found",
        PermissionDenied => "permission denied",
        NameTooLong => "path too long",
        AlreadyExists => "already exists",
        InvalidArgument => "invalid path",
        IOError => "read failed",
    }
    const m = $"flang: cannot read `{path}`: {label}"
    defer m.deinit()
    println(m.as_view())
}

fn report_build_error(e: &BuildError, path: String) {
    const label = e.* match {
        NoCompilerFound => "no C compiler found",
        CompilerFailed(_) => "the C compiler returned an error",
        SpawnFailed => "could not spawn the C compiler",
        IOError => "I/O error while writing build artifacts",
        LowerFailed => "IR lowering rejected the module",
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

// Spawn the sibling tool with our trailing argv. Tool binaries are
// expected on PATH (or addressable by relative name); the child inherits
// our environment so it sees the same workspace context.
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
