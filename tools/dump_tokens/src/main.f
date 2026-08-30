// dump_tokens - load a .f file, run the lexer, print the token stream.
//
//   <offset>:L<line>  <KindName>  <text>
//       leading:  <n piece(s)>  <text>
//       trailing: <n piece(s)>  <text>
//
// Each piece is one whitespace run or one line comment, printed escaped. Omitted when that side has
// no trivia.

import std.env
import std.io.file
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import flang_core.line_index
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

    const view = source.as_view()
    const idx = line_index(view)
    defer idx.deinit()
    for i in 0..tokens.len {
        const prev_end = if i == 0 { 0 } else {
            const p = tokens[i - 1]
            p.offset + p.text.len
        }
        const next_off = if i + 1 < tokens.len { tokens[i + 1].offset } else { view.len }
        print_token(&tokens[i], view, prev_end, next_off, &idx)
    }
    return 0
}

// Trivia and line are derived from the source, which this dumper pays for on demand.
fn print_token(tok: &Token, source: String, prev_end: usize, next_off: usize, idx: &LineIndex) {
    let line = string_builder(96)
    defer line.deinit()
    line.append(tok.offset)
    line.append(":L")
    line.append(idx.line_of(tok.offset) + 1)
    line.append("  ")
    line.append(tok.kind.to_string())
    line.append("  ")
    append_token_text_preview(&line, tok.text)
    println(line.as_view())

    print_trivia_line("    leading: ", trivia_in(source, prev_end, tok.offset))
    print_trivia_line("    trailing:", trivia_in(source, tok.offset + tok.text.len, next_off))
}

fn print_trivia_line(label: String, it: TriviaIter) {
    let pieces: List(Trivia) = list(4)
    defer pieces.deinit()
    let walk = it
    loop {
        const t = walk.next()
        if t.is_none() {
            break
        }
        pieces.push(t.unwrap())
    }
    if pieces.len == 0 {
        return
    }
    let line = string_builder(96)
    defer line.deinit()
    line.append(label)
    line.append(" ")
    line.append(pieces.len)
    line.append(if pieces.len == 1 { " piece   " } else { " pieces  " })
    append_trivia_text(&line, pieces.as_slice())
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
        if c == '\n' {
            sb.append("\\n")
        }
        else if c == '\r' {
            sb.append("\\r")
        }
        else if c == '\t' {
            sb.append("\\t")
        }
        else {
            sb.append_byte(c)
        }
    }
}
