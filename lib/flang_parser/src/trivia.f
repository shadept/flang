// Trivia - whitespace, comments, blank lines.
//
// Non-semantic byte ranges attached to adjacent tokens as leading or trailing. Concatenating every
// token's leading + text + trailing reproduces the source file byte-for-byte: this is the invariant
// the formatter relies on.

import std.option
import std.string

pub type TriviaKind = enum {
    Whitespace
    LineComment
}

// A single piece of trivia. `text` is a view into the original source buffer (no copy). Lifetime is
// tied to the source file's backing string.
pub type Trivia = struct {
    kind: TriviaKind
    text: String
}

// ─────────────────────────────────────────────────────────────────────────
// Deriving trivia from the source
// ─────────────────────────────────────────────────────────────────────────
//
// Trivia is not stored. The bytes between one token's text and the next ARE the trivia between
// them, so the runs are a pure function of the source and two offsets - keeping them on `Token`
// meant a heap slice per token recording what the offsets already said.
//
// Every walk is bounded by the next token's offset, and that bound is load-bearing rather than
// defensive: inside an interpolated string the bytes after a hole's `}` are the string's own
// segment token, not trivia. An unbounded scan would claim them and emit them twice.

fn is_horizontal_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r'
}

fn is_ws(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n'
}

fn starts_comment(source: String, p: usize, limit: usize) bool {
    return p + 1 < limit and source[p] == '/' and source[p + 1] == '/'
}

// Where the trivia after a token ending at `from` stops belonging to THAT token and starts
// belonging to the next one: at most one run of horizontal whitespace, at most one line comment, at
// most one newline. Never scans past `limit`, the next token's offset.
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

// Where the trivia starting at `from` ends - the first byte that belongs to a token. This is the
// leading-side counterpart of `trailing_end`, and the lexer skips trivia with it, so the rule for
// what counts as trivia lives here only.
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

// Walks the runs in `[from, to)` in order - whitespace and line comments, alternating. Yields views
// into `source`; allocates nothing.
//
// Whitespace is merged across newlines into one run. Consumers that care about newline COUNTS read
// them out of the run's text; the only thing a run boundary ever encoded was the leading/trailing
// split, and that is `trailing_end`'s job.
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
    // Not trivia after all - the caller's bounds were wrong. Stop rather than mis-classify.
    self.pos = self.end
    return null
}

// True when the range holds a newline - the question `Token.line` was stored to answer.
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
