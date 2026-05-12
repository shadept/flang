// dump_tokens — load a .f file, run the lexer, print the token stream.
//
//   <offset>:L<line>  <KindName>  <text>
//       leading:  <n piece(s)>  <text>
//       trailing: <n piece(s)>  <text>
//
// Each piece is one whitespace run or one line comment; the printed
// text is the full preserved trivia content (escaped). Omitted when
// there is no trivia on that side.

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
    line.append(":L")
    line.append(tok.line + 1)
    line.append("  ")
    line.append(tok.kind.to_string())
    line.append("  ")
    append_token_text_preview(&line, tok.text)
    println(line.as_view())

    if tok.leading.len > 0 {
        print_trivia_line("    leading: ", tok.leading)
    }
    if tok.trailing.len > 0 {
        print_trivia_line("    trailing:", tok.trailing)
    }
}

fn print_trivia_line(label: String, pieces: Trivia[]) {
    let line = string_builder(96)
    defer line.deinit()
    line.append(label)
    line.append(" ")
    line.append(pieces.len)
    line.append(if pieces.len == 1 { " piece   "} else { " pieces  "})
    append_trivia_text(&line, pieces)
    println(line.as_view())
}

fn append_trivia_text(sb: &StringBuilder, pieces: Trivia[]) {
    let total: usize = 0
    for i in 0..pieces.len {
        total = total + pieces[i].text.len
    }
    if total == 0 {
        sb.append("<empty>")
        return
    }
    sb.append_byte('`' as u8)
    let printed: usize = 0
    for i in 0..pieces.len {
        const text = pieces[i].text
        if printed + text.len > TEXT_PREVIEW_LIMIT {
            const room = if printed >= TEXT_PREVIEW_LIMIT { 0usize } else { TEXT_PREVIEW_LIMIT - printed }
            if room > 0 {
                append_escaped(sb, text[0..room])
            }
            sb.append("...`")
            return
        }
        append_escaped(sb, text)
        printed = printed + text.len
    }
    sb.append_byte('`' as u8)
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

