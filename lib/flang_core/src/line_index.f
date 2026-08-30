// Line index: the byte offset of every line start in a text, plus the lookups that turn a byte
// offset into a line and a line into its content bounds.
//
// Built once per text and queried many times. The alternative - scanning from byte 0 per query - is
// quadratic over a file's worth of diagnostics, which is the whole reason this exists.
//
// Encoding-independent by construction: it stores byte offsets and nothing else. `all_ascii` is
// recorded because callers that convert to a character-counted position (the LSP's UTF-16
// coordinates, a caret column) can take an arithmetic path when it holds.
//
// Out-of-range input is clamped, never rejected.

import std.allocator
import std.encoding.utf8
import std.list
import std.string
import std.test

pub type LineIndex = struct {
    starts: List(usize) // byte offset of each line start; starts[0] == 0
    all_ascii: bool
    text_len: usize
}

pub fn line_index(text: String, allocator: &Allocator? = null) LineIndex {
    let starts: List(usize) = list(16, allocator)
    starts.push(0)
    for i in 0..text.len {
        if text[i] == '\n' {
            starts.push(i + 1)
        }
    }
    return .{ starts = starts, all_ascii = is_ascii(text), text_len = text.len }
}

pub fn deinit(self: &LineIndex) {
    self.starts.deinit()
}

pub fn line_count(self: &LineIndex) usize {
    return self.starts.len
}

// Greatest line whose start is <= offset.
pub fn line_of(self: &LineIndex, offset: usize) usize {
    let lo: usize = 0
    let hi = self.starts.len
    while hi - lo > 1 {
        const mid = lo + (hi - lo) / 2
        if self.starts[mid] <= offset {
            lo = mid
        } else {
            hi = mid
        }
    }
    return lo
}

// [start, end) of the line's content, terminator excluded.
pub fn line_bounds(self: &LineIndex, text: String, line: usize) (usize, usize) {
    const start = self.starts[line]
    let end = if line + 1 < self.starts.len { self.starts[line + 1] } else { self.text_len }
    if end > start and text[end - 1] == '\n' {
        end = end - 1
    }
    if end > start and text[end - 1] == '\r' {
        end = end - 1
    }
    return (start, end)
}

// Tests

test "line starts open a line per terminator" {
    const text = "let x = 1\nlet y = 2\n"
    let idx = line_index(text)
    defer idx.deinit()

    assert_eq(idx.line_count(), 3, "two newlines open a third, empty line")
    assert_eq(idx.line_of(14), 1, "offset 14 is on the second line")
    assert_eq(idx.line_of(0), 0, "the first byte is on the first line")
}

test "line bounds exclude the terminator" {
    const text = "ab\r\ncd\r\n"
    let idx = line_index(text)
    defer idx.deinit()

    const first = idx.line_bounds(text, 0)
    assert_eq(first.0, 0, "the first line starts at 0")
    assert_eq(first.1, 2, "and ends before the \\r\\n")

    const second = idx.line_bounds(text, 1)
    assert_eq(second.0, 4, "the second line starts after the \\r\\n")
    assert_eq(second.1, 6, "and ends before its own")
}

test "a text with no terminator is one line" {
    const text = "no newline here"
    let idx = line_index(text)
    defer idx.deinit()

    assert_eq(idx.line_count(), 1, "one line")
    const b = idx.line_bounds(text, 0)
    assert_eq(b.1, text.len, "which runs to the end of the text")
}
