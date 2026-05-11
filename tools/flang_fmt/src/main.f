// flang_fmt — FLang source formatter.
//
//   flang_fmt <file.f> [...]    rewrite each input in place
//
// Normalization (trivia-only):
//   - CRLF / CR  → LF
//   - Strip trailing horizontal whitespace
//   - Collapse 3+ newlines to 2 (one blank line max)
//   - End the file with exactly one newline

import std.env
import std.io.file
import std.list
import std.result
import std.string
import std.string_builder
import flang_parser.lexer
import flang_parser.parser
import flang_parser.cst
import flang_parser.token
import flang_parser.trivia

pub fn main() i32 {
    let args = get_args()
    defer args.deinit()
    if args.len < 2 {
        println("usage: flang_fmt <file.f> [...]")
        return 1
    }

    const argv = args.as_slice()
    let exit_code = 0i32
    for i in 1..argv.len {
        const status = format_file(argv[i])
        if status != 0 { exit_code = status }
    }
    return exit_code
}

fn format_file(path: String) i32 {
    const open_result = open_file(path, FileMode.Read)
    if open_result.is_err() {
        report_error("cannot open", path)
        return 1
    }
    let read_file = open_result.unwrap()
    const read_result = read_all(&read_file)
    close_file(&read_file)
    if read_result.is_err() {
        report_error("read failed", path)
        return 1
    }
    let source = read_result.unwrap()
    defer source.deinit()

    const formatted = format_source(source.as_view())
    defer formatted.deinit()

    if formatted.as_view() == source.as_view() {
        return 0
    }

    const write_result = open_file(path, FileMode.Write)
    if write_result.is_err() {
        report_error("cannot write", path)
        return 1
    }
    let write_handle = write_result.unwrap()
    const w = write(&write_handle, formatted.as_view())
    close_file(&write_handle)
    if w.is_err() {
        report_error("write failed", path)
        return 1
    }
    return 0
}

fn report_error(reason: String, path: String) {
    const msg = $"flang_fmt: {reason}: {path}"
    defer msg.deinit()
    println(msg.as_view())
}

// ─────────────────────────────────────────────────────────────────────────
// Pipeline
// ─────────────────────────────────────────────────────────────────────────

fn format_source(source: String) OwnedString {
    let lx = lexer(source)
    let tokens = lx.tokenize()
    let p = parser(tokens)
    const cst = p.parse_module()

    let raw = string_builder(source.len + 16)
    emit_node(&raw, &cst)

    const raw_owned = raw.to_string()
    const result = normalize(raw_owned.as_view())
    raw_owned.deinit()
    return result
}

fn emit_node(sb: &StringBuilder, node: &CstNode) {
    for i in 0..node.children.len {
        const child = node.children[i]
        child match {
            NodeChild(inner) => emit_node(sb, &inner),
            TokenChild(tok) => emit_token(sb, &tok),
        }
    }
}

fn emit_token(sb: &StringBuilder, tok: &Token) {
    for i in 0..tok.leading.len {
        sb.append(tok.leading[i].text)
    }
    sb.append(tok.text)
    for i in 0..tok.trailing.len {
        sb.append(tok.trailing[i].text)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Normalization
// ─────────────────────────────────────────────────────────────────────────

fn normalize(source: String) OwnedString {
    const staged = strip_carriage_returns(source)
    const trimmed = trim_lines_and_collapse_blanks(staged.as_view())
    const final = ensure_single_trailing_newline(trimmed.as_view())
    staged.deinit()
    trimmed.deinit()
    return final
}

fn strip_carriage_returns(source: String) OwnedString {
    let sb = string_builder(source.len)
    let i = 0usize
    while i < source.len {
        const ch = source[i]
        if ch == '\r' {
            sb.append_byte('\n' as u8)
            if i + 1 < source.len and source[i + 1] == '\n' {
                i = i + 1
            }
        } else {
            sb.append_byte(ch)
        }
        i = i + 1
    }
    return sb.to_string()
}

fn trim_lines_and_collapse_blanks(source: String) OwnedString {
    let sb = string_builder(source.len)
    let line_start = 0usize
    let blank_streak = 0usize
    let i = 0usize
    loop {
        if i > source.len { break }
        const at_eof = i == source.len
        const at_newline = !at_eof and source[i] == '\n'
        if at_eof or at_newline {
            let line_end = i
            while line_end > line_start and is_horizontal_ws(source[line_end - 1]) {
                line_end = line_end - 1
            }
            const is_blank = line_end == line_start
            if is_blank {
                blank_streak = blank_streak + 1
                if blank_streak <= 1 and !at_eof {
                    sb.append_byte('\n' as u8)
                }
            } else {
                blank_streak = 0
                sb.append(source[line_start..line_end])
                if !at_eof {
                    sb.append_byte('\n' as u8)
                }
            }
            line_start = i + 1
            if at_eof { break }
        }
        i = i + 1
    }
    return sb.to_string()
}

fn ensure_single_trailing_newline(source: String) OwnedString {
    let end = source.len
    while end > 0 and is_trailing_ws(source[end - 1]) {
        end = end - 1
    }
    let sb = string_builder(end + 1)
    sb.append(source[0..end])
    if end > 0 {
        sb.append_byte('\n' as u8)
    }
    return sb.to_string()
}

fn is_horizontal_ws(c: u8) bool {
    return c == ' ' or c == '\t'
}

fn is_trailing_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n'
}
