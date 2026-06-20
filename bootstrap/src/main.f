// bootstrap — the FLang compiler, written in FLang.
//
//   bootstrap [--help] [--version] [-v|--verbose] <command> [args...]
//
//   commands:
//     build <file.f>        compile a source file
//     fmt   <file.f>...     format files via tools/flang_fmt
//     lsp                   start the language server via tools/flang_lsp
//
// The fmt/lsp subcommands shell out to sibling tool binaries via
// std.process — they're separate projects that also depend on
// flang_parser + flang_core.

import std.env
import std.list
import std.option
import std.process
import std.result
import std.string
import std.string_builder
import flang_parser.lexer
import flang_core.diagnostic
import flang_typer.checker

// Parsed CLI state. `subcommand` is the first positional argument; the
// remainder of argv after the subcommand is passed through to whatever
// handler we dispatch to.
type Cli = struct {
    show_help: bool
    show_version: bool
    verbose: bool
    subcommand: String
    rest_index: usize
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
        "build" => run_build(argv, cli.rest_index, cli.verbose)
        "fmt" => spawn_tool("flang_fmt", argv, cli.rest_index, cli.verbose)
        "lsp" => spawn_tool("flang_lsp", argv, cli.rest_index, cli.verbose)
        "cst" => spawn_tool("cst_explorer", argv, cli.rest_index, cli.verbose)
        "tokens" => spawn_tool("dump_tokens", argv, cli.rest_index, cli.verbose)
        else => unknown_subcommand(cli.subcommand)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// CLI parsing
// ─────────────────────────────────────────────────────────────────────────

// Drive std.env.getopts over `argv[1..]`, then pick the first non-option
// argument as the subcommand. Index 0 is the program name and is skipped.
fn parse_cli(argv: String[]) Cli {
    let cli: Cli
    let opts = getopts("h(help)V(version)v(verbose)", argv, 1)

    // Drive opts.next() manually rather than `for r in opts` — std.env's
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
    println("  build  <file.f>      compile a FLang source file")
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

// ─────────────────────────────────────────────────────────────────────────
// Subcommand handlers
// ─────────────────────────────────────────────────────────────────────────

fn run_build(argv: String[], rest: usize, verbose: bool) i32 {
    if rest >= argv.len {
        println("bootstrap: `build` requires an input file")
        return 1
    }
    const path = argv[rest]
    const msg = $"would compile: {path}"
    defer msg.deinit()
    println(msg.as_view())
    if verbose {
        const me = project_info()
        const v = $"  (bootstrap {me.version}, parser {parser_version()})"
        defer v.deinit()
        println(v.as_view())
    }
    return 0
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
        const msg = $"bootstrap: failed to spawn `{tool}` — is it on PATH?"
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
