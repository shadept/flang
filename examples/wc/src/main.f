import std.io.file
import std.io.reader
import std.list
import std.string_builder
import std.string
import std.env
import std.option

fn is_whitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r'
}

fn count(r: Reader, lines: &usize, words: &usize, bytes_count: &usize) {
    let buf = [0u8; 4096]
    let br = buffered_reader(r, buf)
    let in_word = false

    loop {
        let b = br.read_byte() match {
            Some(v) => v,
            None => break
        }

        bytes_count.* = bytes_count.* + 1

        if b == '\n' {
            lines.* = lines.* + 1
        }

        if is_whitespace(b) {
            in_word = false
        } else {
            if !in_word {
                words.* = words.* + 1
                in_word = true
            }
        }
    }
}

fn print_counts(sb: &StringBuilder, lines: usize, words: usize, bytes_count: usize,
                show_lines: bool, show_words: bool, show_bytes: bool, name: String) {
    sb.clear()
    if show_lines { sb.append(lines, "8") }
    if show_words { sb.append(words, "8") }
    if show_bytes { sb.append(bytes_count, "8") }
    if name.len > 0 {
        sb.append(" ")
        sb.append(name)
    }
    println(sb.as_view())
}

pub fn main() i32 {
    let show_lines = false
    let show_words = false
    let show_bytes = false

    let argv = get_args()
    defer argv.deinit()
    let opts = getopts("l(lines)w(words)c(bytes)", argv.as_slice()[1..])
    let files: List(String) = list(0)
    defer files.deinit()

    for r in opts {
        r match {
            Opt('l') => { show_lines = true }
            Opt('w') => { show_words = true }
            Opt('c') => { show_bytes = true }
            NonOpt(s) => { if s.len > 0 { files.push(s) } }
            _ => {}
        }
    }

    // Default: show all if no flags specified
    if !show_lines and !show_words and !show_bytes {
        show_lines = true
        show_words = true
        show_bytes = true
    }

    let sb = string_builder(64)
    defer sb.deinit()

    let total_lines: usize = 0
    let total_words: usize = 0
    let total_bytes: usize = 0

    if files.len == 0 {
        // Read from stdin
        let lines: usize = 0
        let words: usize = 0
        let bytes_count: usize = 0
        count(stdin.reader(), &lines, &words, &bytes_count)
        print_counts(&sb, lines, words, bytes_count, show_lines, show_words, show_bytes, "")
    } else {
        for i in 0..files.len {
            const a = files[i]
            const f = open_file(a, FileMode.Read)
            if f.is_err() {
                print("wc: ")
                print(a)
                println(": No such file or directory")
                continue
            }
            const file = f.unwrap()
            let lines: usize = 0
            let words: usize = 0
            let bytes_count: usize = 0
            count(file.reader(), &lines, &words, &bytes_count)
            close_file(&file)
            print_counts(&sb, lines, words, bytes_count, show_lines, show_words, show_bytes, a)
            total_lines = total_lines + lines
            total_words = total_words + words
            total_bytes = total_bytes + bytes_count
        }
        if files.len > 1 {
            print_counts(&sb, total_lines, total_words, total_bytes, show_lines, show_words, show_bytes, "total")
        }
    }

    return 0
}
