// Object-like macros, expanded by the C preprocessor itself.
//
// Preprocessing deletes `#define`s, and MSVC has no `-dM` to list them. Instead the names are read
// off the library's header text, and a probe file asks the preprocessor to expand each one between
// markers the parser recognises. Whatever a name expands to (`0x20u`, `SDL_UINT64_C(1)`, a string)
// arrives as tokens; a name the headers did not end up defining comes back as itself.

import std.collections.list
import std.collections.set
import std.string
import std.string_builder
import std.test

import flang_bindgen.lexer

/// Write a C file that includes `header` and then marks the expansion of every object-like macro
/// `#define`d in `texts`, the library's header files.
pub fn probe_source(header: String, texts: String[]) OwnedString {
    let seen: Set(String) = set()
    defer seen.deinit()
    let sb = string_builder(4096)
    sb.append("#include \"")
    for i in 0..header.len {
        sb.append_byte(if header[i] == '\\' { '/' as u8 } else { header[i] })
    }
    sb.append("\"\n")
    for text in texts {
        let i: usize = 0
        while i < text.len {
            const end = line_end(text, i)
            const name = define_name(text[i..end])
            if name.len > 0 and seen.add(name) {
                sb.append("__flang_probe \"")
                sb.append(name)
                sb.append("\" ")
                sb.append(name)
                sb.append(" __flang_end\n")
            }
            i = end + 1
        }
    }
    return sb.to_string()
}

// The name an object-like `#define` line introduces, or "" for any other line. A function-like
// macro has `(` straight after its name.
fn define_name(line: String) String {
    let i = skip_blanks(line, 0)
    if i >= line.len or line[i] != '#' {
        return ""
    }
    i = skip_blanks(line, i + 1)
    if !line[i..line.len].starts_with("define") {
        return ""
    }
    i = i + 6
    const after = skip_blanks(line, i)
    if after == i {
        return ""
    }
    const start = after
    let j = start
    while j < line.len and is_ident_char(line[j]) {
        j = j + 1
    }
    if j == start or (j < line.len and line[j] == '(') {
        return ""
    }
    return line[start..j]
}

test "object-like defines are probed once, function-like ones never" {
    const texts = [
        "#define A 1\n#  define B(x) x\n#define C\n# define A 2\n#ifndef D\n",
        "#define E \"e\"\n",
    ]
    const src = probe_source("C:\\inc\\lib.h", texts)
    defer src.deinit()
    const expect = "#include \"C:/inc/lib.h\"\n__flang_probe \"A\" A __flang_end\n__flang_probe \"C\" C __flang_end\n__flang_probe \"E\" E __flang_end\n"
    assert_eq(src.view(), expect, "probe file")
}
