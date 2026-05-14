// cst_explorer — load a .f file, lex + parse, emit JSON or timing info.
//
//   cst_explorer <file.f> [-t|--time] [-n|--iterations N]
//
// Default behaviour: emit the JSON dump (source + tokens + CST + AST +
// diagnostics) to stdout. cst_explorer_web consumes this format.
//
//   -t, --time            measure lex + parse latency instead of dumping;
//                         reports min/avg/max on stderr
//   -n, --iterations N    iteration count for --time (default 1)

import std.env
import std.io.file
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import std.time
import std.conv
import flang_parser.lexer
import flang_parser.parser
import flang_parser.cst
import flang_parser.token
import flang_parser.trivia
import flang_parser.ast
import flang_parser.projector
import flang_core.diagnostic
import flang_core.span
import cst_explorer.ast_json

type Options = struct {
    path: String
    time_mode: bool
    iterations: usize
    help: bool
}

pub fn main() i32 {
    let args = get_args()
    defer args.deinit()

    let opts: Options = .{
        path = "",
        time_mode = false,
        iterations = 1,
        help = false,
    }
    let parsed = parse_args(args.as_slice(), &opts)
    if !parsed { return 1 }
    if opts.help { print_usage(); return 0 }

    if opts.path.len == 0 {
        print_usage()
        return 1
    }

    if opts.time_mode {
        return run_timing(opts.path, opts.iterations)
    }

    const source_opt = read_source(opts.path)
    if source_opt.is_none() { return 1 }
    let source = source_opt.unwrap()
    defer source.deinit()

    let lx = lexer(source.as_view())
    let tokens = lx.tokenize()
    defer tokens.deinit()

    let p = parser(tokens)
    defer p.deinit()
    const cst = p.parse_module()

    let ast = project_module(cst, 0i32)
    defer ast.deinit()
    print_json(opts.path, source.as_view(), &tokens, &cst, &ast, &p.diagnostics)
    return if p.diagnostics.len > 0 { 1i32 } else { 0i32 }
}

fn read_source(path: String) OwnedString? {
    const open_result = open_file(path, FileMode.Read)
    if open_result.is_err() {
        const msg = $"cst_explorer: cannot open `{path}`"
        defer msg.deinit()
        println(msg.as_view())
        return null
    }
    let file = open_result.unwrap()
    const read_result = read_all(&file)
    close_file(&file)
    if read_result.is_err() {
        const msg = $"cst_explorer: read failed `{path}`"
        defer msg.deinit()
        println(msg.as_view())
        return null
    }
    return read_result.unwrap()
}

fn print_usage() {
    println("usage: cst_explorer <file.f> [-t|--time] [-n|--iterations N]")
    println("")
    println("  (default)             emit JSON dump (source + tokens + CST + AST + diagnostics)")
    println("                        to stdout — consumed by tools/cst_explorer_web")
    println("  -t, --time            measure lex + parse latency instead of dumping;")
    println("                        min/avg/max are reported on stderr")
    println("  -n, --iterations N    iteration count for --time (default 1)")
}

// Returns false on a parse error (caller exits non-zero).
fn parse_args(argv: String[], opts: &Options) bool {
    let it = getopts("t(time)n(iterations):h(help)", argv, 1)
    for r in it {
        r match {
            Opt('t') => { opts.time_mode = true }
            Opt('h') => { opts.help = true }
            OptArg('n', v) => {
                const parsed = parse_usize(v)
                if parsed.is_err() {
                    const msg = $"cst_explorer: --iterations expects an integer, got `{v}`"
                    defer msg.deinit()
                    println(msg.as_view())
                    return false
                }
                opts.iterations = parsed.unwrap().0 as usize
                if opts.iterations == 0 { opts.iterations = 1 }
            }
            NonOpt(s) => {
                if opts.path.len == 0 {
                    opts.path = s
                } else {
                    const msg = $"cst_explorer: unexpected argument `{s}`"
                    defer msg.deinit()
                    println(msg.as_view())
                    return false
                }
            }
            Error(ch) => {
                const msg = $"cst_explorer: unknown option `-{ch as char}`"
                defer msg.deinit()
                println(msg.as_view())
                return false
            }
            MissingArg(ch) => {
                const msg = $"cst_explorer: option `-{ch as char}` requires a value"
                defer msg.deinit()
                println(msg.as_view())
                return false
            }
            _ => {}
        }
    }
    return true
}

// ─────────────────────────────────────────────────────────────────────────
// Timing mode (--time)
//
// Runs lex + parse repeatedly without producing the CST printout. We
// report per-phase min/avg/max in microseconds plus the source size and
// final token count. Output goes to stderr so callers can `cst_explorer
// foo.f --time | …` without polluting downstream consumers.
// ─────────────────────────────────────────────────────────────────────────

// Owns the source read so the OwnedString lives for the duration of
// the measured loop. Passing the view from main's frame produced an
// empty view at the call boundary — keeping the OwnedString local to
// this frame dodges the issue.
fn run_timing(path: String, iterations: usize) i32 {
    const source_opt = read_source(path)
    if source_opt.is_none() { return 1 }
    let source = source_opt.unwrap()
    defer source.deinit()
    const view = source.as_view()

    let lex_min: u64 = 18446744073709551615
    let lex_max: u64 = 0
    let lex_sum: u64 = 0
    let parse_min: u64 = 18446744073709551615
    let parse_max: u64 = 0
    let parse_sum: u64 = 0
    let project_min: u64 = 18446744073709551615
    let project_max: u64 = 0
    let project_sum: u64 = 0
    let total_min: u64 = 18446744073709551615
    let total_max: u64 = 0
    let total_sum: u64 = 0
    let tokens_seen: usize = 0
    let diagnostics_seen: usize = 0

    for it in 0..iterations {
        const t0 = monotonic_ns()
        let lx = lexer(view)
        let tokens = lx.tokenize()
        const t_lex = monotonic_ns()

        let p = parser(tokens)
        const cst = p.parse_module()
        const t_parse = monotonic_ns()

        let ast = project_module(cst, 0i32)
        const t_project = monotonic_ns()

        const lex_ns = t_lex - t0
        const parse_ns = t_parse - t_lex
        const project_ns = t_project - t_parse
        const total_ns = t_project - t0

        if lex_ns < lex_min { lex_min = lex_ns }
        if lex_ns > lex_max { lex_max = lex_ns }
        lex_sum = lex_sum + lex_ns

        if parse_ns < parse_min { parse_min = parse_ns }
        if parse_ns > parse_max { parse_max = parse_ns }
        parse_sum = parse_sum + parse_ns

        if project_ns < project_min { project_min = project_ns }
        if project_ns > project_max { project_max = project_ns }
        project_sum = project_sum + project_ns

        if total_ns < total_min { total_min = total_ns }
        if total_ns > total_max { total_max = total_ns }
        total_sum = total_sum + total_ns

        tokens_seen = tokens.len
        diagnostics_seen = p.diagnostics.len

        ast.deinit()
        p.deinit()
        tokens.deinit()
    }

    print_timing_banner(path, view.len, tokens_seen, diagnostics_seen, iterations)
    print_timing_row("lex    ", lex_min, lex_max, lex_sum, iterations)
    print_timing_row("parse  ", parse_min, parse_max, parse_sum, iterations)
    print_timing_row("project", project_min, project_max, project_sum, iterations)
    print_timing_row("total  ", total_min, total_max, total_sum, iterations)
    return if diagnostics_seen > 0 { 1i32 } else { 0i32 }
}

fn eprintln(line: String) {
    const _r1 = stderr.write(line)
    const _r2 = stderr.write("\n")
}

fn print_timing_banner(path: String, bytes: usize, tokens: usize, diagnostics: usize, iterations: usize) {
    const banner = $"{path}: {bytes} bytes, {tokens} tokens, {diagnostics} diagnostics — {iterations} iter"
    defer banner.deinit()
    eprintln(banner.as_view())
}

fn print_timing_row(label: String, min_ns: u64, max_ns: u64, sum_ns: u64, iterations: usize) {
    const avg_us = (sum_ns as f64) / (iterations as f64) / 1000.0
    const min_us = (min_ns as f64) / 1000.0
    const max_us = (max_ns as f64) / 1000.0
    const line = $"  {label}  min {min_us:.3} µs   avg {avg_us:.3} µs   max {max_us:.3} µs"
    defer line.deinit()
    eprintln(line.as_view())
}

// ─────────────────────────────────────────────────────────────────────────
// JSON emitter. Schema:
//   { file, source, tokens[], tree (CST), ast, diagnostics[] }
// Tokens are an indexed array; the CST `tree` references them by integer
// to avoid duplicating `text`/`leading`/`trailing` blobs at every leaf.
// ─────────────────────────────────────────────────────────────────────────

fn print_json(path: String, source: String, tokens: &List(Token), cst: &CstNode, ast: &Module, diagnostics: &List(Diagnostic)) {
    let sb = string_builder(source.len * 4 + 4096)
    defer sb.deinit()

    sb.append("{\"file\":")
    append_json_string(&sb, path)
    sb.append(",\"source\":")
    append_json_string(&sb, source)

    sb.append(",\"tokens\":[")
    for i in 0..tokens.len {
        if i > 0 { sb.append(",") }
        emit_token_json(&sb, &tokens[i])
    }
    sb.append("]")

    sb.append(",\"tree\":")
    emit_node_json(&sb, cst, tokens)

    sb.append(",\"ast\":")
    ast_to_json(&sb, ast)

    sb.append(",\"diagnostics\":[")
    for i in 0..diagnostics.len {
        if i > 0 { sb.append(",") }
        emit_diagnostic_json(&sb, &diagnostics[i])
    }
    sb.append("]")

    sb.append("}")
    println(sb.as_view())
}

fn emit_node_json(sb: &StringBuilder, node: &CstNode, tokens: &List(Token)) {
    sb.append("{\"kind\":\"")
    sb.append(node.kind.to_string())
    sb.append("\",\"start\":")
    sb.append(node.start)
    sb.append(",\"end\":")
    sb.append(node.end)
    sb.append(",\"children\":[")
    for i in 0..node.children.len {
        if i > 0 { sb.append(",") }
        const child = node.children[i]
        child match {
            NodeChild(inner) => {
                sb.append("{\"node\":")
                emit_node_json(sb, &inner, tokens)
                sb.append("}")
            },
            TokenChild(tok) => {
                sb.append("{\"token\":")
                sb.append(find_token_index(tokens, &tok))
                sb.append("}")
            },
        }
    }
    sb.append("]}")
}

// Linear scan — fine for a diagnostic tool, not a hot path.
fn find_token_index(tokens: &List(Token), tok: &Token) usize {
    for i in 0..tokens.len {
        if tokens[i].offset == tok.offset and tokens[i].text.len == tok.text.len {
            return i
        }
    }
    return 0usize
}

fn emit_token_json(sb: &StringBuilder, tok: &Token) {
    sb.append("{\"kind\":\"")
    sb.append(tok.kind.to_string())
    sb.append("\",\"offset\":")
    sb.append(tok.offset)
    sb.append(",\"line\":")
    sb.append(tok.line)
    sb.append(",\"text\":")
    append_json_string(sb, tok.text)
    sb.append(",\"leading\":")
    emit_trivia_json(sb, tok.leading)
    sb.append(",\"trailing\":")
    emit_trivia_json(sb, tok.trailing)
    sb.append("}")
}

fn emit_trivia_json(sb: &StringBuilder, pieces: Trivia[]) {
    sb.append("[")
    for i in 0..pieces.len {
        if i > 0 { sb.append(",") }
        sb.append("{\"kind\":\"")
        sb.append(if pieces[i].kind == TriviaKind.LineComment { "LineComment" } else { "Whitespace" })
        sb.append("\",\"text\":")
        append_json_string(sb, pieces[i].text)
        sb.append("}")
    }
    sb.append("]")
}

fn emit_diagnostic_json(sb: &StringBuilder, d: &Diagnostic) {
    sb.append("{\"code\":")
    append_json_string(sb, d.code)
    sb.append(",\"message\":")
    append_json_string(sb, d.message.as_view())
    sb.append(",\"start\":")
    sb.append(d.span.start)
    sb.append(",\"length\":")
    sb.append(d.span.length)
    sb.append("}")
}

fn append_json_string(sb: &StringBuilder, s: String) {
    sb.append_byte('"')
    for i in 0..s.len {
        const c = s[i]
        if c == '"' { sb.append("\\\"") }
        else if c == '\\' { sb.append("\\\\") }
        else if c == '\n' { sb.append("\\n") }
        else if c == '\r' { sb.append("\\r") }
        else if c == '\t' { sb.append("\\t") }
        else if c == 0x08 { sb.append("\\b") }
        else if c == 0x0C { sb.append("\\f") }
        else if c < 0x20 {
            sb.append("\\u00")
            sb.append_byte(hex_nibble(c >> 4))
            sb.append_byte(hex_nibble(c & 0x0F))
        }
        else { sb.append_byte(c) }
    }
    sb.append_byte('"')
}

fn hex_nibble(n: u8) u8 {
    if n < 10 { return '0' + n }
    return 'a' + (n - 10)
}
