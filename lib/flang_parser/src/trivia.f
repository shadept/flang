// Trivia - whitespace, comments, blank lines.
//
// Non-semantic byte ranges attached to adjacent tokens as leading or trailing. Concatenating every
// token's leading + text + trailing reproduces the source file byte-for-byte, the invariant the
// formatter relies on.

import std.option
import std.string
import std.string_builder
import std.test

pub type TriviaKind = enum {
    Whitespace
    LineComment
}

// A single piece of trivia. `text` is a view into the source buffer, live as long as it is.
pub type Trivia = struct {
    kind: TriviaKind
    text: String
}

// ─────────────────────────────────────────────────────────────────────────
// Deriving trivia from the source
// ─────────────────────────────────────────────────────────────────────────
//
// Trivia is not stored: the bytes between one token's text and the next are the trivia between
// them, a pure function of the source and two offsets.
//
// Every walk is bounded by the next token's offset. The bound is load-bearing: inside an
// interpolated string the bytes after a hole's `}` are the string's own segment token, not trivia,
// and an unbounded scan would claim them and emit them twice.

fn is_horizontal_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r'
}

fn is_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n'
}

fn starts_comment(source: String, p: usize, limit: usize) bool {
    return p + 1 < limit and source[p] == '/' and source[p + 1] == '/'
}

// Where the trivia after a token ending at `from` stops belonging to it: at most one run of
// horizontal whitespace, one line comment, one newline. Never scans past `limit`, the next token's
// offset.
pub fn trailing_end(source: String, from: usize, limit: usize) usize {
    let p = from
    while p < limit and is_horizontal_ws(source[p]) {
        p = p + 1
    }
    if starts_comment(source, p, limit) {
        p = p + 2
        while p < limit and source[p] != '\n' {
            p = p + 1
        }
    }
    if p < limit and source[p] == '\n' {
        p = p + 1
    }
    return p
}

// Where the trivia starting at `from` ends: the first byte that belongs to a token.
pub fn leading_end(source: String, from: usize) usize {
    let p = from
    loop {
        if p >= source.len {
            break
        }
        if is_ws(source[p]) {
            while p < source.len and is_ws(source[p]) {
                p = p + 1
            }
            continue
        }
        if starts_comment(source, p, source.len) {
            p = p + 2
            while p < source.len and source[p] != '\n' {
                p = p + 1
            }
            continue
        }
        break
    }
    return p
}

// Walks the runs in `[from, to)` in order, yielding views into `source` and allocating nothing.
// Whitespace is merged across newlines into one run; a consumer that needs newline counts reads
// them out of the run's text.
pub type TriviaIter = struct {
    source: String
    pos: usize
    end: usize
}

pub fn trivia_in(source: String, from: usize, to: usize) TriviaIter {
    return .{ source = source, pos = from, end = to }
}

pub fn next(self: &TriviaIter) Trivia? {
    if self.pos >= self.end {
        return null
    }
    const start = self.pos
    if is_ws(self.source[self.pos]) {
        while self.pos < self.end and is_ws(self.source[self.pos]) {
            self.pos = self.pos + 1
        }
        return Some(Trivia { kind = TriviaKind.Whitespace, text = self.source[start..self.pos] })
    }
    if starts_comment(self.source, self.pos, self.end) {
        self.pos = self.pos + 2
        while self.pos < self.end and self.source[self.pos] != '\n' {
            self.pos = self.pos + 1
        }
        return Some(Trivia { kind = TriviaKind.LineComment, text = self.source[start..self.pos] })
    }
    // Not trivia after all: the caller's bounds were wrong. Stop rather than mis-classify.
    self.pos = self.end
    return null
}

// True when the range holds a newline.
pub fn spans_newline(source: String, from: usize, to: usize) bool {
    let p = from
    while p < to and p < source.len {
        if source[p] == '\n' {
            return true
        }
        p = p + 1
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────────
// Docstrings
// ─────────────────────────────────────────────────────────────────────────
//
// A docstring is the run of `//` lines directly above a declaration: nothing but indentation on
// each line before the `//`, and no blank line between the run and the declaration. The same run at
// the top of a file, ended by a blank line, documents the module. It is trivia read as prose: `//`
// and one following space dropped from every line.

// The docstring of the declaration whose first token sits at `offset`, or null when no comment run
// sits directly above it (the token does not start its line, or the line above is not a comment).
pub fn doc_above(source: String, offset: usize) OwnedString? {
    let p = offset
    while p > 0 and is_horizontal_ws(source[p - 1]) {
        p = p - 1
    }
    if p == 0 or source[p - 1] != '\n' {
        return null
    }
    let line_end = p - 1
    let first: usize? = null
    loop {
        let ls = line_end
        while ls > 0 and source[ls - 1] != '\n' {
            ls = ls - 1
        }
        let q = ls
        while q < line_end and is_horizontal_ws(source[q]) {
            q = q + 1
        }
        if !starts_comment(source, q, line_end) {
            break
        }
        first = Some(q)
        if ls == 0 {
            break
        }
        line_end = ls - 1
    }
    if first.is_none() {
        return null
    }
    return Some(comment_prose(source[first.unwrap()..(p - 1)]))
}

// The module docstring: the comment run the file opens with, when a blank line (or the end of the
// file) separates it from what follows. A run glued to the first declaration is that declaration's.
pub fn module_doc(source: String) OwnedString? {
    let p: usize = 0
    loop {
        let q = p
        while q < source.len and is_horizontal_ws(source[q]) {
            q = q + 1
        }
        if !starts_comment(source, q, source.len) {
            break
        }
        while p < source.len and source[p] != '\n' {
            p = p + 1
        }
        if p < source.len {
            p = p + 1
        }
    }
    if p < source.len and source[p] != '\n' and source[p] != '\r' {
        return null
    }
    return doc_above(source, p)
}

// A run of comment lines as prose: indentation, `//` and one following space dropped from each,
// trailing whitespace trimmed, joined with newlines.
fn comment_prose(block: String) OwnedString {
    let sb = string_builder(block.len)
    let p: usize = 0
    let first = true
    while p < block.len {
        let e = p
        while e < block.len and block[e] != '\n' {
            e = e + 1
        }
        let line = trim(block[p..e])
        if starts_with(line, "//") {
            line = line[2..line.len]
        }
        if line.len > 0 and line[0] == ' ' {
            line = line[1..line.len]
        }
        if !first {
            sb.append("\n")
        }
        sb.append(trim_end(line))
        first = false
        p = e + 1
    }
    return sb.to_string()
}

// A docstring rendered as markdown, Go's doc-comment rules: paragraphs separated by blank lines, a
// line opening (indented or not) with `-`, `*`, `+` or `1.` starts a list item and indented lines
// under it continue that item, any other run of indented lines is a code block, everything else is
// prose (wrapped lines flow together; backtick spans are inline code as in markdown).
pub fn doc_markdown(doc: String) OwnedString {
    let sb = string_builder(doc.len + 32)
    let in_code = false
    let in_list = false
    let p: usize = 0
    while p <= doc.len {
        let e = p
        while e < doc.len and doc[e] != '\n' {
            e = e + 1
        }
        const line = doc[p..e]
        const indented = line.len > 0 and (line[0] == ' ' or line[0] == '\t')
        const body = trim_start(line)
        if body.len == 0 {
            close_code(&sb, &in_code)
            in_list = false
            sb.append("\n")
        } else if starts_list_item(body) {
            close_code(&sb, &in_code)
            in_list = true
            sb.append(line)
            sb.append("\n")
        } else if indented and in_list {
            sb.append("  ")
            sb.append(body)
            sb.append("\n")
        } else if indented {
            if !in_code {
                sb.append("```flang\n")
                in_code = true
            }
            sb.append(line)
            sb.append("\n")
        } else {
            close_code(&sb, &in_code)
            sb.append(line)
            sb.append("\n")
        }
        p = e + 1
    }
    close_code(&sb, &in_code)
    const out = trim_end(sb.as_view())
    const owned = from_view(out)
    sb.deinit()
    return move owned
}

fn close_code(sb: &StringBuilder, in_code: &bool) {
    if in_code.* {
        sb.append("```\n")
        in_code.* = false
    }
}

// `- x`, `* x`, `+ x`, `3. x` or `3) x`.
fn starts_list_item(body: String) bool {
    if body.len >= 2 and (body[0] == '-' or body[0] == '*' or body[0] == '+') and body[1] == ' ' {
        return true
    }
    let i: usize = 0
    while i < body.len and body[i] >= '0' and body[i] <= '9' {
        i = i + 1
    }
    return i > 0 and i + 1 < body.len and (body[i] == '.' or body[i] == ')') and body[i + 1] == ' '
}

test "doc_markdown fences indented runs and keeps list continuations" {
    const md = doc_markdown("Prose that\nwraps.\n\n  let x = 1\n  x + 1\n\n  - first item\n    continued\n2. second\nTail.")
    assert_true(md.as_view() == "Prose that\nwraps.\n\n```flang\n  let x = 1\n  x + 1\n```\n\n  - first item\n  continued\n2. second\nTail.",
        "code fenced, list continuation indented, prose untouched")
    md.deinit()
    const plain = doc_markdown("Just prose.")
    assert_true(plain.as_view() == "Just prose.", "prose passes through")
    plain.deinit()
}

test "doc_above collects the comment run glued to a declaration" {
    const src = "// Adds one.\n//\n//   Indented.\nfn inc(x: i32) i32 { return x + 1 }\n"
    const d = doc_above(src, 31)
    assert_true(d.is_some(), "a docstring")
    const text = unwrap(move d)
    assert_true(text.as_view() == "Adds one.\n\n  Indented.", "prefix stripped, lines kept")
    text.deinit()
}

test "doc_above stops at a blank line, a code line and a trailing comment" {
    const src = "// far\n\nfn a() {}\nlet x = 1 // near\nfn b() {}\n"
    assert_true(doc_above(src, 8).is_none(), "blank line breaks the run")
    assert_true(doc_above(src, 36).is_none(), "a trailing comment is not a docstring")
    assert_true(doc_above(src, 3).is_none(), "an offset mid-line has no run above")
}

test "doc_above honours indentation and CRLF" {
    const src = "type S = struct {\r\n    // The x.\r\n    x: i32\r\n}\r\n"
    const d = doc_above(src, 38)
    assert_true(d.is_some(), "an indented field docstring")
    const text = unwrap(move d)
    assert_true(text.as_view() == "The x.", "CR trimmed")
    text.deinit()
}

test "module_doc takes the opening run only when a blank line follows it" {
    const m = module_doc("// Trivia.\n// More.\n\nimport std.option\n")
    assert_true(m.is_some(), "module docstring present")
    const text = unwrap(move m)
    assert_true(text.as_view() == "Trivia.\nMore.", "module docstring")
    text.deinit()
    assert_true(module_doc("// see\nfn f() {}\n").is_none(), "glued to the first decl")
    assert_true(module_doc("import std.option\n").is_none(), "no opening comment")
    const eof = module_doc("// only\n")
    assert_true(eof.is_some(), "end of file closes the run")
    const last = unwrap(move eof)
    assert_true(last.as_view() == "only", "end of file closes the run")
    last.deinit()
}
