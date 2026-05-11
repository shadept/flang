// dump_tokens — load a .f file, run the lexer, print the token stream.
//
//   <offset>  <KindName>  <text-or-summary>  (leading=<n> trailing=<m>)

import std.env
import std.io.file
import std.list
import std.result
import std.string
import std.string_builder
import flang_parser.lexer
import flang_parser.token
import flang_parser.trivia

const TEXT_PREVIEW_LIMIT: usize = 64

pub fn main() i32 {
    let args = get_args()
    defer args.deinit()
    if args.len < 2 {
        println("usage: dump_tokens <file.f>")
        return 1
    }

    const argv = args.as_slice()
    const path = argv[1]

    const open_result = open_file(path, FileMode.Read)
    if open_result.is_err() {
        const msg = $"dump_tokens: cannot open {path}"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    let file = open_result.unwrap()
    const read_result = read_all(&file)
    close_file(&file)
    if read_result.is_err() {
        const msg = $"dump_tokens: read failed: {path}"
        defer msg.deinit()
        println(msg.as_view())
        return 1
    }
    let source = read_result.unwrap()
    defer source.deinit()

    let lx = lexer(source.as_view())
    let tokens = lx.tokenize()

    const banner = $"{path}: {tokens.len} token(s)"
    defer banner.deinit()
    println(banner.as_view())

    for i in 0..tokens.len {
        print_token(&tokens[i])
    }
    return 0
}

fn print_token(tok: &Token) {
    let line = string_builder(96)
    defer line.deinit()
    line.append(tok.offset)
    line.append("  ")
    line.append(tok.kind.to_string())
    line.append("  ")
    append_token_text_preview(&line, tok.text)
    line.append("  (leading=")
    line.append(tok.leading.len)
    line.append(" trailing=")
    line.append(tok.trailing.len)
    line.append(")")
    println(line.as_view())
}

fn append_token_text_preview(sb: &StringBuilder, text: String) {
    if text.len == 0 {
        sb.append("<empty>")
        return
    }
    if text.len <= TEXT_PREVIEW_LIMIT + 3 {
        sb.append_byte('`' as u8)
        append_escaped(sb, text)
        sb.append_byte('`' as u8)
        return
    }
    sb.append_byte('`' as u8)
    append_escaped(sb, text[0..TEXT_PREVIEW_LIMIT])
    sb.append("...`")
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

