// Trivia - whitespace, comments, blank lines.
//
// Non-semantic byte ranges attached to adjacent tokens as leading or trailing. Concatenating every
// token's leading + text + trailing reproduces the source file byte-for-byte, the invariant the
// formatter relies on.

import std.option
import std.string

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
