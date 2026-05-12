// cst_explorer — load a .f file, lex + parse, and print the CST tree.
//
//   cst_explorer <file.f> [--tokens] [--diagnostics-only] [--json] [--time [N]]
//
// Prints an indented tree of CST nodes. Each node shows its `NodeKind`
// and byte range; each token shows its `TokenKind` and an escaped
// preview of its text. With `--tokens`, prints the flat token stream
// instead of the tree. With `--diagnostics-only`, suppresses tree
// output and just lists parser diagnostics. With `--time`, measures
// lex + parse latency (no printing of tokens or tree); pass an integer
// after to run more iterations and report min/avg/max (useful for
// smoothing warmup noise).

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
import flang_core.diagnostic

const TEXT_PREVIEW_LIMIT: usize = 48

type Options = struct {
    path: String
    tokens_only: bool
    diagnostics_only: bool
    json: bool
    time_mode: bool
    iterations: usize
}

pub fn main() i32 {
    let args = get_args()
    defer args.deinit()
    if args.len < 2 {
        println("usage: cst_explorer <file.f> [--tokens] [--diagnostics-only] [--json] [--time [N]]")
        println("")
        println("  --json        emit JSON describing source + tokens + tree + diagnostics")
        println("                (consumed by tools/cst_explorer_web for visualisation)")
        println("  --time [N]    measure lex + parse latency without printing tree;")
        println("                runs N iterations (default 1) and reports min/avg/max")
        return 1
    }

    const argv = args.as_slice()
    let opts: Options = .{
        path = "",
        tokens_only = false,
        diagnostics_only = false,
        json = false,
        time_mode = false,
        iterations = 1,
    }
    let i: usize = 1
    while i < argv.len {
        const a = argv[i]
        if a == "--tokens" { opts.tokens_only = true }
        else if a == "--diagnostics-only" { opts.diagnostics_only = true }
        else if a == "--json" { opts.json = true }
        else if a == "--time" {
            opts.time_mode = true
            // Optional positional iteration count immediately after.
            if i + 1 < argv.len {
                const peek = argv[i + 1]
                const parsed = parse_usize(peek)
                if parsed.is_ok() {
                    opts.iterations = parsed.unwrap().0 as usize
                    if opts.iterations == 0 { opts.iterations = 1 }
                    i = i + 1
                }
            }
        }
        else if opts.path.len == 0 { opts.path = a }
        else {
            const msg = $"cst_explorer: unexpected argument `{a}`"
            defer msg.deinit()
            println(msg.as_view())
            return 1
        }
        i = i + 1
    }
    if opts.path.len == 0 {
        println("cst_explorer: missing input file")
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

    if opts.tokens_only and !opts.json {
        print_token_stream(opts.path, &tokens)
        return 0
    }

    let p = parser(tokens)
    defer p.deinit()
    const cst = p.parse_module()

    if opts.json {
        print_json(opts.path, source.as_view(), &tokens, &cst, &p.diagnostics)
        return if p.diagnostics.len > 0 { 1i32 } else { 0i32 }
    }

    if !opts.diagnostics_only {
        const banner = $"{opts.path}: {tokens.len} token(s), CST root = Module"
        defer banner.deinit()
        println(banner.as_view())
        print_node(&cst, 0)
    }

    if p.diagnostics.len > 0 {
        const dbanner = $"-- {p.diagnostics.len} diagnostic(s) --"
        defer dbanner.deinit()
        println(dbanner.as_view())
        for i in 0..p.diagnostics.len {
            print_diagnostic(&p.diagnostics[i])
        }
        return 1
    }
    return 0
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

// ─────────────────────────────────────────────────────────────────────────
// CST printing
// ─────────────────────────────────────────────────────────────────────────

fn print_node(node: &CstNode, depth: usize) {
    let sb = string_builder(128)
    defer sb.deinit()
    append_indent(&sb, depth)
    sb.append(node.kind.to_string())
    sb.append(" [")
    sb.append(node.start)
    sb.append("..")
    sb.append(node.end)
    sb.append("]")
    println(sb.as_view())
    for i in 0..node.children.len {
        const child = node.children[i]
        child match {
            NodeChild(inner) => print_node(&inner, depth + 1),
            TokenChild(tok) => print_token_child(&tok, depth + 1),
        }
    }
}

fn print_token_child(tok: &Token, depth: usize) {
    let sb = string_builder(96)
    defer sb.deinit()
    append_indent(&sb, depth)
    sb.append("• ")
    sb.append(tok.kind.to_string())
    sb.append(" ")
    append_token_text_preview(&sb, tok.text)
    println(sb.as_view())
    // Show comments-as-leading-trivia so doc comments surface in the tree.
    if has_comment_trivia(tok.leading) {
        print_comment_trivia(tok.leading, "leading", depth + 1)
    }
    if has_comment_trivia(tok.trailing) {
        print_comment_trivia(tok.trailing, "trailing", depth + 1)
    }
}

fn has_comment_trivia(pieces: Trivia[]) bool {
    for i in 0..pieces.len {
        if pieces[i].kind == TriviaKind.LineComment { return true }
    }
    return false
}

fn print_comment_trivia(pieces: Trivia[], side: String, depth: usize) {
    let sb = string_builder(96)
    defer sb.deinit()
    append_indent(&sb, depth)
    sb.append("// ")
    sb.append(side)
    sb.append(" comment: ")
    for i in 0..pieces.len {
        if pieces[i].kind == TriviaKind.LineComment {
            append_escaped(&sb, pieces[i].text)
            sb.append(" ")
        }
    }
    println(sb.as_view())
}

fn append_indent(sb: &StringBuilder, depth: usize) {
    for i in 0..depth {
        sb.append("  ")
    }
}

fn append_token_text_preview(sb: &StringBuilder, text: String) {
    if text.len == 0 {
        sb.append("<empty>")
        return
    }
    sb.append_byte('`' as u8)
    if text.len <= TEXT_PREVIEW_LIMIT {
        append_escaped(sb, text)
    } else {
        append_escaped(sb, text[0..TEXT_PREVIEW_LIMIT])
        sb.append("...")
    }
    sb.append_byte('`' as u8)
}

fn append_escaped(sb: &StringBuilder, s: String) {
    for i in 0..s.len {
        const c = s[i]
        if c == '\n' { sb.append("\\n") }
        else if c == '\r' { sb.append("\\r") }
        else if c == '\t' { sb.append("\\t") }
        else { sb.append_byte(c) }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Token stream (--tokens)
// ─────────────────────────────────────────────────────────────────────────

fn print_token_stream(path: String, tokens: &List(Token)) {
    const banner = $"{path}: {tokens.len} token(s)"
    defer banner.deinit()
    println(banner.as_view())
    for i in 0..tokens.len {
        let sb = string_builder(96)
        defer sb.deinit()
        sb.append(tokens[i].offset)
        sb.append(":L")
        sb.append(tokens[i].line + 1)
        sb.append("  ")
        sb.append(tokens[i].kind.to_string())
        sb.append("  ")
        append_token_text_preview(&sb, tokens[i].text)
        println(sb.as_view())
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Diagnostics
// ─────────────────────────────────────────────────────────────────────────

fn print_diagnostic(d: &Diagnostic) {
    let sb = string_builder(128)
    defer sb.deinit()
    sb.append("[")
    sb.append(d.code)
    sb.append("] ")
    sb.append(d.message.as_view())
    sb.append(" (")
    sb.append(d.span.start)
    sb.append("..")
    sb.append(d.span.start + d.span.length)
    sb.append(")")
    println(sb.as_view())
}

// ─────────────────────────────────────────────────────────────────────────
// Timing mode (--time)
//
// Runs lex + parse repeatedly without producing the CST printout. Each
// iteration tokenises the source and parses it to a CST; the produced
// tree is dropped immediately so the working set stays small. We
// report per-phase min/avg/max in microseconds, plus the source size
// and final token count so callers can correlate output to input.
// ─────────────────────────────────────────────────────────────────────────

// Owns the source read so the OwnedString lives for the duration of
// the measured loop. Passing the view from main's frame produced an
// empty view at the call boundary (the OwnedString header on the
// caller's stack didn't survive the parameter-passing path under the
// current C codegen) — keeping the OwnedString local to this frame
// dodges the issue.
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
        const _cst = p.parse_module()
        const t_parse = monotonic_ns()

        const lex_ns = t_lex - t0
        const parse_ns = t_parse - t_lex
        const total_ns = t_parse - t0

        if lex_ns < lex_min { lex_min = lex_ns }
        if lex_ns > lex_max { lex_max = lex_ns }
        lex_sum = lex_sum + lex_ns

        if parse_ns < parse_min { parse_min = parse_ns }
        if parse_ns > parse_max { parse_max = parse_ns }
        parse_sum = parse_sum + parse_ns

        if total_ns < total_min { total_min = total_ns }
        if total_ns > total_max { total_max = total_ns }
        total_sum = total_sum + total_ns

        tokens_seen = tokens.len
        diagnostics_seen = p.diagnostics.len

        p.deinit()
        tokens.deinit()
    }

    print_timing_banner(path, view.len, tokens_seen, diagnostics_seen, iterations)
    print_timing_row("lex  ", lex_min, lex_max, lex_sum, iterations)
    print_timing_row("parse", parse_min, parse_max, parse_sum, iterations)
    print_timing_row("total", total_min, total_max, total_sum, iterations)
    return if diagnostics_seen > 0 { 1i32 } else { 0i32 }
}

fn print_timing_banner(path: String, bytes: usize, tokens: usize, diagnostics: usize, iterations: usize) {
    const banner = $"{path}: {bytes} bytes, {tokens} tokens, {diagnostics} diagnostics — {iterations} iter"
    defer banner.deinit()
    println(banner.as_view())
}

fn print_timing_row(label: String, min_ns: u64, max_ns: u64, sum_ns: u64, iterations: usize) {
    const avg_us = (sum_ns as f64) / (iterations as f64) / 1000.0
    const min_us = (min_ns as f64) / 1000.0
    const max_us = (max_ns as f64) / 1000.0
    const line = $"  {label}  min {min_us:.3} µs   avg {avg_us:.3} µs   max {max_us:.3} µs"
    defer line.deinit()
    println(line.as_view())
}

// ─────────────────────────────────────────────────────────────────────────
// JSON emitter (--json)
//
// Schema (consumed by tools/cst_explorer_web):
// {
//   "file": "/abs/path.f",
//   "source": "raw source text",
//   "tokens": [
//     { "kind": "Pub", "offset": 0, "line": 0, "text": "pub",
//       "leading": [{ "kind": "Whitespace"|"LineComment", "text": "…" }, …],
//       "trailing": [...] }
//   ],
//   "tree": { "kind": "Module", "start": 0, "end": 68,
//             "children": [ { "node": {...} } | { "token": <token-index> } ] },
//   "diagnostics": [{ "code": "E1001", "message": "...",
//                     "start": 0, "length": 3 }]
// }
//
// Tokens are emitted as an indexed array; the tree references them by
// integer to avoid duplicating large `text`/`leading`/`trailing` blobs.
// ─────────────────────────────────────────────────────────────────────────

fn print_json(path: String, source: String, tokens: &List(Token), cst: &CstNode, diagnostics: &List(Diagnostic)) {
    let sb = string_builder(source.len * 2 + 1024)
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

// Locate a token by identity (offset is unique within a parse). Linear
// scan is fine for the diagnostic tool — the CST tree is the hot path,
// not this lookup.
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

// JSON-safe quoting per RFC 8259: backslash-escape `"`, `\`, and the
// C0 control characters. Non-ASCII bytes pass through as-is — the
// source is already UTF-8 and browsers accept it raw.
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
