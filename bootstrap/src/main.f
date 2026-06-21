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
import std.io.fs
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
    subcommand: String
    rest_index: usize
    stdlib_path: String
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
        "build" => run_build(argv, cli.rest_index, cli.verbose, cli.stdlib_path)
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
    let opts = getopts("h(help)V(version)v(verbose)s(stdlib-path):", argv, 1)

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
            }
            OptArg(c, val) => {
                if c == 's' { cli.stdlib_path = val }
            }
            NonOpt(s) => {
                cli.subcommand = s
                cli.rest_index = opts.rest_index()
                break
            }
            Error(c) => {
                const msg = $"bootstrap: unrecognized option `-{c}`"
                defer msg.deinit()
                println(msg.as_view())
                cli.show_help = true
                break
            }
            MissingArg(c) => {
                const msg = $"bootstrap: option `-{c}` requires an argument"
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
    println("bootstrap - FLang compiler")
    println("")
    println("usage: bootstrap [options] <command> [args...]")
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
}

fn print_version() {
    const me = project_info()
    const banner = $"{me.name} {me.version} (flang_parser {parser_version()})"
    defer banner.deinit()
    println(banner.as_view())
}

fn unknown_subcommand(name: String) i32 {
    const msg = $"bootstrap: unknown command `{name}`"
    defer msg.deinit()
    println(msg.as_view())
    print_help()
    return 1
}

// Subcommand handlers

// build: analyse a single file through the shared `flang_driver` pipeline
// and report every diagnostic. The driver (lex -> parse -> project -> check)
// is invoked here in `main.f`; `frontend` owns file reading and rendering.
// build: a `<file>.f` argument compiles that single file; with no
// argument, load `flang.toml` from the current directory and build the
// project. Both share `build_source_file` for the analyse->lower->link tail.
fn run_build(argv: String[], rest: usize, verbose: bool, stdlib_path: String) i32 {
    if rest < argv.len {
        const path = argv[rest]
        if ends_with(path, ".f") {
            const out = output_path_for(path)
            return build_source_file(path, out, verbose)
        }
        const msg = $"bootstrap: `build` takes a `.f` file or no argument (got `{path}`)"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    return build_project(verbose, stdlib_path)
}

// Project mode: parse `flang.toml`, glob its sources, resolve imports
// across the whole project (plus the auto-imported prelude), type-check
// every module together, then lower the lot to one executable.
fn build_project(verbose: bool, stdlib_path: String) i32 {
    if !exists("flang.toml") {
        println("bootstrap: no flang.toml in the current directory")
        return 1
    }
    const toml_opt = read_source("flang.toml")
    if toml_opt.is_none() { return 1 }
    let toml = toml_opt.unwrap()
    defer toml.deinit()

    let proj = parse_project(toml.as_view())
    defer proj.deinit()

    let sources = glob_sources(proj.source.as_view())
    defer deinit_source_list(&sources)

    if sources.len == 0 {
        const m = $"bootstrap: no sources match `{proj.source.as_view()}`"
        defer m.deinit()
        println(m.as_view())
        return 1
    }

    let ctx = resolve_ctx(&proj, stdlib_path)
    defer ctx.deinit()

    let unit = analyze_project(&ctx, &sources)
    defer unit.deinit()

    render_project_diagnostics(&unit.diagnostics, &unit.file_paths, &unit.sources)

    const errs = project_error_count(&unit)
    if verbose {
        const v = $"  ({unit.modules.len} modules, {unit.result.node_types.len()} nodes typed)"
        defer v.deinit()
        println(v.as_view())
    }
    if errs > 0 {
        const m = $"build failed: {errs} error(s)"
        defer m.deinit()
        println(m.as_view())
        return 1
    }

    const out = $"{proj.output.as_view()}/{proj.name.as_view()}"
    defer out.deinit()
    let result = build_program(&unit.modules, &unit.result, out.as_view())
    if result.is_err() {
        report_build_error(&result.unwrap_err(), proj.name.as_view())
        return 1
    }
    let artifact = result.unwrap()
    defer artifact.deinit()
    const msg = $"built {artifact.executable_path.as_view()}"
    defer msg.deinit()
    println(msg.as_view())
    return 0
}

// Read, analyse, report diagnostics, then lower + link to `out`.
fn build_source_file(path: String, out: String, verbose: bool) i32 {
    const source_opt = read_source(path)
    if source_opt.is_none() { return 1 }
    let unit = analyze(source_opt.unwrap(), path)
    defer unit.deinit()

    render_diagnostics(&unit.diagnostics, path, unit.source.as_view())

    const errs = error_count(&unit)
    if verbose {
        const v = $"  ({unit.module.decls.len} decls, {unit.result.node_types.len()} nodes typed)"
        defer v.deinit()
        println(v.as_view())
    }
    if errs > 0 {
        return build_failed(path, errs)
    }

    let result = build_unit(&unit, out)
    if result.is_err() {
        report_build_error(&result.unwrap_err(), path)
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
        const v = $"bootstrap: spawning `{tool}`"
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
        const msg = $"bootstrap: failed to spawn `{tool}` - is it on PATH?"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    let child = spawn_result.unwrap()
    defer child.deinit()

    const wait_result = child.wait()
    if wait_result.is_err() {
        const msg = $"bootstrap: `{tool}` wait failed"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    return wait_result.unwrap()
}
