// Tokens of preprocessed C, as `cl /E` and `cc -E` print it.
//
// Preprocessing leaves three kinds of directive line behind: line markers naming the file the
// following text came from (`# 12 "f.h" 1` from GNU compilers, `#line 12 "f.h"` from MSVC),
// `#pragma` lines, and nothing else. Every token carries the index of the file it came from, so a
// declaration can be told apart by origin.

import std.collections.list
import std.string
import std.test

pub type CTokKind = enum {
    Ident
    Number
    Str
    CharLit
    Punct
    // A `#pragma ...` line; `text` is everything after `pragma`.
    Pragma
    Eof
}

pub type CTok = struct {
    kind: CTokKind
    text: String
    // Index into `CLexed.files`.
    file: u32
    line: u32
}

pub type CLexed = struct {
    toks: List(CTok)
    // Each file as its line marker spells it, quotes stripped, escapes still in place.
    files: List(String)
}

pub fn deinit(self: move CLexed) {
    self.toks.deinit()
    self.files.deinit()
}

pub fn is_punct(self: &CTok, p: String) bool {
    return self.kind == CTokKind.Punct and self.text == p
}

pub fn is_ident(self: &CTok, name: String) bool {
    return self.kind == CTokKind.Ident and self.text == name
}

/// Split preprocessed C into tokens, tagging each with its source file and line.
pub fn lex_c(src: String) CLexed {
    let toks: List(CTok) = list(src.len / 4)
    let files: List(String) = list(8)
    files.push("")
    let file: u32 = 0
    let line: u32 = 1
    let i: usize = 0
    let at_line_start = true
    while i < src.len {
        const c = src[i]
        if c == '\n' {
            line = line + 1
            at_line_start = true
            i = i + 1
            continue
        }
        if c == ' ' or c == '\t' or c == '\r' or c == 12u8 {
            i = i + 1
            continue
        }
        if c == '#' and at_line_start {
            const end = line_end(src, i)
            const d = read_directive(src[i + 1..end])
            d match {
                Marker(m) => {
                    file = file_index(&files, m.file)
                    // The marker names the line after it; the newline ending the marker counts it.
                    line = if m.line > 0 { m.line - 1 } else { 0 }
                    i = end
                    continue
                }
                PragmaLine(text) => {
                    toks.push(CTok {
                        kind = CTokKind.Pragma,
                        text = text,
                        file = file,
                        line = line,
                    })
                }
                Other => {}
            }
            i = end
            continue
        }
        at_line_start = false
        const start = i
        const kind = scan_token(src, &i)
        toks.push(CTok { kind = kind, text = src[start..i], file = file, line = line })
    }
    toks.push(CTok { kind = CTokKind.Eof, text = "", file = file, line = line })
    return CLexed { toks = move toks, files = move files }
}

type Marker = struct {
    file: String
    line: u32
}

type Directive = enum {
    Marker(Marker)
    PragmaLine(String)
    Other
}

pub fn line_end(src: String, from: usize) usize {
    let i = from
    while i < src.len and src[i] != '\n' {
        i = i + 1
    }
    return i
}

// `body` is the directive line without its `#`: ` 12 "f.h" 1`, `line 12 "f.h"`, `pragma pack(8)`.
fn read_directive(body: String) Directive {
    let i = skip_blanks(body, 0)
    if body[i..body.len].starts_with("pragma") {
        return Directive.PragmaLine(body[i + 6..body.len].trim())
    }
    if body[i..body.len].starts_with("line") {
        i = skip_blanks(body, i + 4)
    }
    const num_start = i
    let n: u32 = 0
    while i < body.len and body[i] >= '0' and body[i] <= '9' {
        n = n * 10 + (body[i] - '0') as u32
        i = i + 1
    }
    if i == num_start {
        return Directive.Other
    }
    i = skip_blanks(body, i)
    if i >= body.len or body[i] != '"' {
        return Directive.Other
    }
    const q = i + 1
    let j = q
    while j < body.len and body[j] != '"' {
        if body[j] == '\\' {
            j = j + 1
        }
        j = j + 1
    }
    const end = if j < body.len { j } else { body.len }
    return Directive.Marker(Marker { file = body[q..end], line = n })
}

pub fn skip_blanks(s: String, from: usize) usize {
    let i = from
    while i < s.len and (s[i] == ' ' or s[i] == '\t') {
        i = i + 1
    }
    return i
}

fn file_index(files: &List(String), name: String) u32 {
    for k in 0..files.len {
        if files[k] == name {
            return k as u32
        }
    }
    files.push(name)
    return (files.len - 1) as u32
}

// Advance `i` past one token starting at it and say what it was.
fn scan_token(src: String, i: &usize) CTokKind {
    const c = src[i.*]
    if is_ident_start(c) {
        while i.* < src.len and is_ident_char(src[i.*]) {
            i.* = i.* + 1
        }
        // An encoding prefix glued to a literal (`L"x"`, `u8"x"`) belongs to the literal.
        if i.* < src.len and (src[i.*] == '"' or src[i.*] == '\'') {
            return scan_quoted(src, i, src[i.*])
        }
        return CTokKind.Ident
    }
    const next_is_digit = i.* + 1 < src.len and src[i.* + 1] >= '0' and src[i.* + 1] <= '9'
    if (c >= '0' and c <= '9') or (c == '.' and next_is_digit) {
        scan_number(src, i)
        return CTokKind.Number
    }
    if c == '"' or c == '\'' {
        return scan_quoted(src, i, c)
    }
    i.* = i.* + punct_len(src, i.*)
    return CTokKind.Punct
}

// A preprocessing number: digits, letters, `_`, `.`, and a sign right after an exponent letter.
fn scan_number(src: String, i: &usize) {
    while i.* < src.len {
        const c = src[i.*]
        const is_exp = (c == 'e' or c == 'E' or c == 'p' or c == 'P') and i.* + 1 < src.len
            and (src[i.* + 1] == '+' or src[i.* + 1] == '-')
        if is_exp {
            i.* = i.* + 2
            continue
        }
        if !is_ident_char(c) and c != '.' {
            return
        }
        i.* = i.* + 1
    }
}

fn scan_quoted(src: String, i: &usize, quote: u8) CTokKind {
    i.* = i.* + 1
    while i.* < src.len and src[i.*] != quote and src[i.*] != '\n' {
        if src[i.*] == '\\' {
            i.* = i.* + 1
        }
        i.* = i.* + 1
    }
    if i.* < src.len and src[i.*] == quote {
        i.* = i.* + 1
    }
    return if quote == '"' { CTokKind.Str } else { CTokKind.CharLit }
}

fn punct_len(src: String, at: usize) usize {
    const rest = src[at..src.len]
    if rest.starts_with("...") or rest.starts_with("<<=") or rest.starts_with(">>=") {
        return 3
    }
    const two = [
        "->", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "##", "++", "--", "+=", "-=", "*=",
        "/=", "%=", "&=", "|=", "^=",
    ]
    for p in two {
        if rest.starts_with(p) {
            return 2
        }
    }
    return 1
}

fn is_ident_start(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$'
}

pub fn is_ident_char(c: u8) bool {
    return is_ident_start(c) or (c >= '0' and c <= '9')
}

test "line markers in both spellings set the file and line" {
    const lexed = lex_c("#line 3 \"a.h\"\nint x;\n# 7 \"b.h\" 1\nchar y;\n")
    defer lexed.deinit()
    assert_eq(lexed.files.len, 3 as usize, "default plus two files")
    assert_eq(lexed.toks[0].text, "int", "first token")
    assert_eq(lexed.files[lexed.toks[0].file as usize], "a.h", "MSVC marker")
    assert_eq(lexed.toks[0].line, 3u32, "MSVC line")
    assert_eq(lexed.files[lexed.toks[3].file as usize], "b.h", "GNU marker")
    assert_eq(lexed.toks[3].line, 7u32, "GNU line")
}

test "pragma lines become tokens, other directives vanish" {
    const lexed = lex_c("#pragma pack(push, 1)\n#define X 1\nint a;\n")
    defer lexed.deinit()
    assert_eq(lexed.toks[0].kind == CTokKind.Pragma, true, "pragma token")
    assert_eq(lexed.toks[0].text, "pack(push, 1)", "pragma text")
    assert_eq(lexed.toks[1].text, "int", "define dropped")
}

test "numbers, literals and punctuators" {
    const lexed = lex_c("0x1Fui64 1.5e-3f L\"w\" 'c' a->b ... <<=")
    defer lexed.deinit()
    assert_eq(lexed.toks[0].text, "0x1Fui64", "suffixed hex")
    assert_eq(lexed.toks[1].text, "1.5e-3f", "exponent sign")
    assert_eq(lexed.toks[2].kind == CTokKind.Str, true, "prefixed string")
    assert_eq(lexed.toks[3].kind == CTokKind.CharLit, true, "char literal")
    assert_eq(lexed.toks[5].text, "->", "arrow")
    assert_eq(lexed.toks[7].text, "...", "ellipsis")
    assert_eq(lexed.toks[8].text, "<<=", "shift assign")
}
